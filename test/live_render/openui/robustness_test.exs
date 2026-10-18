defmodule LiveRender.OpenUI.RobustnessTest do
  @moduledoc """
  Nothing a model writes may crash or hang the client (language.md, sections 8.1 and 10):
  deep nesting, long input, exponential references, runaway evaluation, and random garbage.
  """

  use ExUnit.Case, async: true

  import LiveRender.OpenUI.TestHelpers

  alias LiveRender.OpenUI.{Editing, Evaluator, Parser, Protocol, Serializer}
  alias LiveRender.OpenUI.Parser.Stream

  # Runs `fun` and fails if it takes longer than `ms`.
  defp within(ms, fun) do
    {time, result} = :timer.tc(fun)
    assert time < ms * 1000, "took #{div(time, 1000)}ms, limit #{ms}ms"
    result
  end

  describe "deep nesting" do
    test "10_000 open brackets, parens and braces" do
      for open <- ["[", "(", "{", "Stack(", "@Count(", "{a: "] do
        text = "root = " <> String.duplicate(open, 10_000)
        result = within(2_000, fn -> parse(text) end)
        assert result.incomplete
        within(2_000, fn -> canonical(result) end)
      end
    end

    test "deeply nested built-in calls inside an @Each template" do
      nested = String.duplicate("@Abs(", 150) <> "x" <> String.duplicate(")", 150)
      {value, _, _} = within(2_000, fn -> eval_stmt(~s|v = @Each([-1, 2], "x", #{nested})|) end)
      assert value == [1, 2]
    end

    test "10_000 closed nested arrays" do
      text =
        ~s|root = Stack([Text("" + @Count(| <>
          String.duplicate("[", 10_000) <> String.duplicate("]", 10_000) <> "))])"

      within(2_000, fn -> summary(text) end)
    end

    test "long prefix-operator and ternary chains" do
      within(2_000, fn ->
        summary(~s|root = Stack([Text("" + | <> String.duplicate("!", 10_000) <> "1)])")
      end)

      within(2_000, fn ->
        summary(~s|root = Stack([Text("" + | <> String.duplicate("-", 10_000) <> "1)])")
      end)

      within(2_000, fn ->
        summary(~s|root = Stack([Text("" + | <> String.duplicate("a ? b : ", 10_000) <> "c)])")
      end)
    end

    test "long left-associative operator and member chains" do
      within(5_000, fn ->
        summary(~s|root = Stack([Text("" + | <> String.duplicate("1 + ", 50_000) <> "1)])")
      end)

      within(5_000, fn ->
        summary("root = Stack([Text(x" <> String.duplicate(".a", 50_000) <> ")])")
      end)
    end
  end

  describe "long input" do
    test "a very long string" do
      long = String.duplicate("ab", 1_000_000)
      s = within(3_000, fn -> summary(~s|root = Stack([Text("| <> long <> ~s|")])|) end)
      assert [%{"props" => %{"text" => ^long}}] = s.root["props"]["children"]

      s = within(3_000, fn -> summary("root = Stack([Text('" <> long <> "')])") end)
      assert [%{"props" => %{"text" => ^long}}] = s.root["props"]["children"]
    end

    test "a long string with escapes" do
      long = String.duplicate(~s|a\\nb\\"|, 100_000)
      within(3_000, fn -> summary(~s|root = Stack([Text("| <> long <> ~s|")])|) end)
    end

    test "a long unterminated string" do
      within(3_000, fn -> parse(~s|root = Stack([Text("| <> String.duplicate("x", 1_000_000)) end)
    end

    test "trailing whitespace on long text is trimmed quickly" do
      within(2_000, fn ->
        parse(String.duplicate("a = 1\n", 50_000) <> String.duplicate(" ", 100_000))
      end)
    end

    test "many statements" do
      text =
        Enum.map_join(1..5_000, "\n", &~s|s#{&1} = Text("#{&1}")|) <>
          "\nroot = Stack([" <> Enum.map_join(1..5_000, ", ", &"s#{&1}") <> "])"

      s = within(3_000, fn -> summary(text) end)
      assert length(s.root["props"]["children"]) == 5_000
    end
  end

  describe "exponential references" do
    test "a chain of statements that each reference the next twice is capped" do
      chain =
        Enum.map_join(1..40, "\n", fn i -> "l#{i} = [l#{i + 1}, l#{i + 1}]" end) <> "\nl41 = 1"

      within(3_000, fn -> summary(~s|root = Stack([Text("" + @Count(l1))])\n| <> chain) end)

      cards =
        Enum.map_join(1..40, "\n", fn i -> ~s|c#{i} = Card("x", [c#{i + 1}, c#{i + 1}])| end) <>
          ~s|\nc41 = Text("1")|

      within(5_000, fn -> summary("root = Stack([c1])\n" <> cards) end)
    end

    test "moderate sharing is still expanded in full" do
      chain =
        Enum.map_join(1..10, "\n", fn i -> "l#{i} = [l#{i + 1}, l#{i + 1}]" end) <> "\nl11 = 1"

      {value, _, _} = eval_stmt("v = @Count(l1)\n" <> chain)
      assert value == 2
      {value, _, _} = eval_stmt("v = l1\n" <> chain)
      assert value |> List.flatten() |> length() == 1024
    end
  end

  describe "evaluation budget" do
    @big inspect(Enum.to_list(1..300), limit: :infinity)

    test "a runaway state default gives null instead of hanging" do
      text =
        ~s|$x = @Count(@Each(a, "x", @Each(a, "y", @Each(a, "z", z))))\na = #{@big}\nroot = Stack([])|

      result = within(3_000, fn -> parse(text) end)
      assert result.state["$x"] == nil
    end

    test "Evaluator.eval on its own is budgeted" do
      result = parse(~s|v = @Each(a, "x", @Each(a, "y", @Each(a, "z", z)))\na = #{@big}|)
      {:ok, ast} = fetch_ast(result, "v")
      ctx = Evaluator.ctx(lib(), fn _ -> nil end, fn _ -> nil end)
      assert within(3_000, fn -> Evaluator.eval(ast, ctx) end) == nil
    end

    test "a runaway prop becomes null with a runtime-error, and the rest renders" do
      text =
        ~s|root = Stack([Text("ok"), Text("" + @Count(@Each(a, "x", @Each(a, "y", @Each(a, "z", z)))))])\na = #{@big}|

      s = within(3_000, fn -> summary(text) end)
      assert "runtime-error" in Enum.map(s.errors, & &1["code"])
    end

    defp fetch_ast(result, name) do
      syms = Map.new(result.statements, &{&1.id, &1.expr})
      ctx = %LiveRender.OpenUI.Materializer.Ctx{syms: syms, lib: lib(), current: name}
      {ast, _} = LiveRender.OpenUI.Materializer.expr(syms[name], ctx)
      {:ok, ast}
    end
  end

  describe "fuzzing" do
    @tokens [
              "root",
              "=",
              "Stack",
              "(",
              "[",
              "]",
              ")",
              "{",
              "}",
              ",",
              ":",
              "?",
              ".",
              "!",
              "-",
              "+"
            ] ++
              ["*", "/", "%", "==", "!=", ">", "<", ">=", "<=", "&&", "||", "&", "|", "$x", "$y"] ++
              [
                "@Count",
                "@Each",
                "@Nope",
                "@Set",
                "@Run",
                "@Upper",
                "Action",
                "Query",
                "Mutation"
              ] ++
              ["Text", "Card", "Button", "Input", "Tag", "Metric", "null", "true", "false", "0"] ++
              ["1", "-1", "1.5", "1e", "1e3", ~s("s"), "'s'", ~S("\u12"), ~s("a\\), "'", ~s(")] ++
              ["\n", "\n", "\n", "#", "//", "```", "a", "b", "t", "rows", "]]>openui:content"] ++
              ["]]>openui:end", "@CopyToClipboard", "Form", "Select"]

    defp random_soup(n) do
      Enum.map_join(1..n, fn _ ->
        tok = Enum.random(@tokens)
        if :rand.uniform(3) == 1, do: tok, else: tok <> " "
      end)
    end

    defp random_bytes(n), do: :crypto.strong_rand_bytes(n)

    # Mutates a valid program: deletes, duplicates or inserts a few bytes.
    defp mutate(text) do
      Enum.reduce(1..:rand.uniform(4), text, fn _, t ->
        size = byte_size(t)
        at = if size == 0, do: 0, else: :rand.uniform(size) - 1

        case :rand.uniform(3) do
          1 ->
            binary_part(t, 0, at) <> binary_part(t, min(at + 1, size), size - min(at + 1, size))

          2 ->
            binary_part(t, 0, at) <> Enum.random(@tokens) <> binary_part(t, at, size - at)

          3 ->
            binary_part(t, 0, at) <> random_bytes(1) <> binary_part(t, at, size - at)
        end
      end)
    end

    @seed_programs for f <-
                         Path.wildcard(
                           Path.expand("../../fixtures/openui/1.0/**/input.oui", __DIR__)
                         ),
                       do: File.read!(f)

    defp exercise(text, lib) do
      result = Parser.parse(text, lib)
      %{tree: tree} = LiveRender.OpenUI.Conformance.canonical(result, lib)
      if tree, do: Serializer.to_source(tree, lib)
      _ = Protocol.parse(text, streaming: true)
      _ = Editing.merge(text, text)
      result
    end

    test "parse, evaluate, merge and serialize never raise on random input" do
      lib = lib()
      :rand.seed(:exsss, {42, 42, 42})

      within(9_000, fn ->
        for i <- 1..1_500 do
          text =
            case rem(i, 3) do
              0 -> random_bytes(:rand.uniform(80))
              1 -> random_soup(:rand.uniform(40))
              2 -> mutate(Enum.random(@seed_programs))
            end

          try do
            exercise(text, lib)
          rescue
            e -> flunk("#{inspect(text)} raised #{Exception.format(:error, e, __STACKTRACE__)}")
          end
        end
      end)
    end

    test "the stream parser never raises and still equals parsing" do
      lib = lib()
      :rand.seed(:exsss, {7, 7, 7})

      within(9_000, fn ->
        for i <- 1..400 do
          text =
            if rem(i, 2) == 0,
              do: random_soup(:rand.uniform(30)),
              else: mutate(Enum.random(@seed_programs))

          cut = :rand.uniform(byte_size(text) + 1) - 1
          chunks = [binary_part(text, 0, cut), binary_part(text, cut, byte_size(text) - cut)]

          try do
            s = Enum.reduce(chunks, Stream.new(lib), fn c, s -> elem(Stream.push(s, c), 0) end)
            {_s, final} = Stream.finish(s)

            assert canonical(final, lib) == canonical(Parser.parse(text, lib), lib),
                   inspect(chunks)
          rescue
            e in ExUnit.AssertionError -> reraise e, __STACKTRACE__
            e -> flunk("#{inspect(chunks)} raised #{Exception.format(:error, e, __STACKTRACE__)}")
          end
        end
      end)
    end
  end
end
