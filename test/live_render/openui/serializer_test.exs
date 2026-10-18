defmodule LiveRender.OpenUI.SerializerTest do
  @moduledoc "Serialization (language.md, section 9.2)."

  use ExUnit.Case, async: true

  import LiveRender.OpenUI.TestHelpers

  alias LiveRender.OpenUI.{
    ActionPlan,
    Binding,
    Element,
    ExprParser,
    Lexer,
    Serializer,
    Statements
  }

  defp parse_expr(src) do
    case ("x = " <> src) |> Lexer.tokenize() |> Statements.split() do
      [raw | _] -> ExprParser.parse(raw.tokens)
      [] -> {:null}
    end
  end

  defp to_src(ast), do: Serializer.ast(ast, lib())

  # `-1` serializes as a literal and parses back as one; both mean the same.
  defp norm({:unary, "-", {:num, n}}) when is_number(n) and n > 0, do: {:num, -n}
  defp norm({:unary, "-", {:num, :infinity}}), do: {:num, :neg_infinity}
  defp norm(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&norm/1) |> List.to_tuple()
  defp norm(l) when is_list(l), do: Enum.map(l, &norm/1)
  defp norm(v), do: v

  defp assert_roundtrip(ast) do
    src = to_src(ast)
    back = parse_expr(src)

    assert norm(back) == norm(ast),
           "#{inspect(ast)}\nserialized as #{src}\nparsed as #{inspect(back)}"
  end

  describe "expression round trips" do
    test "parentheses where parsing back would change the grouping" do
      for src <- [
            "a - (b - c)",
            "(a - b) - c",
            "a / (b * c)",
            "-(a + b)",
            "!(a && b)",
            "(a || b) && c",
            "a || b && c",
            "(a ? b : c) ? d : e",
            "a ? b : c ? d : e",
            "a ? (b ? c : d) : e",
            "(a + b).length",
            "(-a).b",
            "(a ? b : c)[0]",
            "(a ? b : c) + 1",
            "a + (b ? c : d)",
            "a == (b == c)",
            "a < (b < c)",
            "-(-a)",
            "- -1",
            "a - -1",
            "!!a",
            "a % (b % c)"
          ] do
        ast = parse_expr(src)
        assert_roundtrip(ast)
      end
    end

    test "the canonical output text" do
      assert to_src(parse_expr("a - (b - c)")) == "a - (b - c)"
      assert to_src(parse_expr("-(a + b)")) == "-(a + b)"
      assert to_src(parse_expr("(a - b) - c")) == "a - b - c"
      assert to_src(parse_expr("a ? b : (c ? d : e)")) == "a ? b : c ? d : e"
      assert to_src(parse_expr("(a ? b : c) ? d : e")) == "(a ? b : c) ? d : e"
    end

    test "literals, collections, calls, members and state" do
      for src <- [
            ~s|"quote \\" and \\\\ and \\n newline"|,
            "[1, -2, 3.5, 1e21, 1e-7, true, false, null]",
            ~s|{a: 1, "b c": 2, "1x": 3, "true": 4, "": 5}|,
            ~s|@Count(@Filter(rows, "status", "==", "open"))|,
            ~s|@Each(rows, "t", Text(t.title))|,
            ~s|Action([@Set($x, $x + 1), @Reset($x), @ToAssistant("hi", {a: 1})])|,
            ~s|m.0.1|,
            ~s|m[0]["k"].length|,
            ~s|Card("t", [Text("a")])|,
            ~s|@Upper("x")|
          ] do
        assert_roundtrip(parse_expr(src))
      end
    end

    test "member fields that are not plain names round-trip" do
      for field <- ["a b", "01", "1e3", "true", "null", "", "?", "-1", "é", "0.10", "x.y"] do
        assert_roundtrip({:member, {:ref, "m"}, field})
      end
    end

    test "unknown @ functions keep their @" do
      assert_roundtrip(parse_expr("@Nope(1)"))
      assert_roundtrip(parse_expr("@lower(1)"))
    end

    test "a binding assignment used as an operand is parenthesized" do
      assert_roundtrip({:bin, "+", {:assign, "$x", {:num, 5}}, {:num, 1}})
    end

    test "infinite numbers" do
      assert to_src({:num, :infinity}) == "1e999"
      assert parse_expr("1e999") == {:num, :infinity}
      assert_roundtrip({:num, :neg_infinity})
    end

    test "random expression trees round-trip" do
      :rand.seed(:exsss, {5, 6, 7})

      for _ <- 1..5000 do
        assert_roundtrip(gen(5))
      end
    end
  end

  # A random expression AST, as the parser could produce it.
  defp gen(0), do: leaf()

  defp gen(d) do
    case :rand.uniform(11) do
      1 ->
        leaf()

      2 ->
        {:bin, Enum.random(~w(|| && == != > < >= <= + - * / %)), gen(d - 1), gen(d - 1)}

      3 ->
        {:unary, Enum.random(["!", "-"]), gen(d - 1)}

      4 ->
        {:ternary, gen(d - 1), gen(d - 1), gen(d - 1)}

      5 ->
        {:member, gen(d - 1),
         Enum.random(["a", "length", "0", "1", "0.5", "Foo", "x y", "true", "01"])}

      6 ->
        {:index, gen(d - 1), gen(d - 1)}

      7 ->
        {:arr, Enum.map(1..:rand.uniform(3), fn _ -> gen(d - 1) end)}

      8 ->
        {:obj, [{"k", gen(d - 1)}, {"a b", gen(d - 1)}]}

      9 ->
        {:call, "Count", [gen(d - 1)], false, nil}

      10 ->
        {:call, "Nope", [gen(d - 1)], true, nil}

      11 ->
        {:assign, "$x", gen(d - 1)}
    end
  end

  defp leaf do
    Enum.random([
      {:num, :rand.uniform(100)},
      {:num, 2.5},
      {:num, -3},
      {:num, 1.0e21},
      {:num, :infinity},
      {:str, "s"},
      {:bool, true},
      {:null},
      {:ref, "a"},
      {:ref, "Foo"},
      {:state, "$s"}
    ])
  end

  describe "tree round trips" do
    test "a program serializes and parses back to an equal tree" do
      program = """
      root = Stack([header, Card("Body", [Text("a", "heading"), Tag("t")]), btn], "row")
      header = Text("Hello \\"world\\"")
      btn = Button("Go", Action([@ToAssistant("go", {id: 1}), @OpenUrl("https://x.y")]), "primary")
      """

      s1 = summary(program)
      %{tree: tree} = LiveRender.OpenUI.Conformance.canonical(parse(program), lib())
      text = Serializer.to_source(tree, lib())
      assert summary(text).root == s1.root
      assert summary(text).errors == []
      # The entry comes first, children before parents.
      assert [first | _] = String.split(text, "\n")
      assert first =~ ~r/^root = Stack\(/
      assert text =~ ~r/header = .*\n(.|\n)*btn = /
    end

    test "trailing nulls for optional props are trimmed; inner ones are kept" do
      tree = %Element{type_name: "Button", props: %{"label" => "x", "variant" => "primary"}}
      assert Serializer.to_source(tree, lib()) == ~s|root = Button("x", null, "primary")|

      assert Serializer.to_source(%Element{type_name: "Button", props: %{"label" => "x"}}, lib()) ==
               ~s|root = Button("x")|
    end

    test "an unfilled required position is held with null" do
      tree = %Element{type_name: "Metric", props: %{"value" => 3}}
      assert Serializer.to_source(tree, lib()) == "root = Metric(null, 3)"
    end

    test "action plans" do
      one = %ActionPlan{steps: [{:continue_conversation, "hi", :none}]}

      many = %ActionPlan{
        steps: [
          {:set, "$x", {:bin, "+", {:state, "$x"}, {:num, 1}}},
          {:reset, ["$x", "$y"]},
          {:run, "q", :query}
        ]
      }

      custom = %ActionPlan{steps: [{:custom, "CopyToClipboard", %{"text" => "a b"}, ["text"]}]}
      empty = %ActionPlan{steps: []}

      for {plan, want} <- [
            {one, ~s|@ToAssistant("hi")|},
            {many, ~s|Action([@Set($x, $x + 1), @Reset($x, $y), @Run(q)])|},
            {custom, ~s|@CopyToClipboard("a b")|},
            {empty, "Action([])"}
          ] do
        tree = %Element{type_name: "Button", props: %{"label" => "b", "action" => plan}}
        assert Serializer.to_source(tree, lib()) == ~s|root = Button("b", #{want})|
      end
    end

    test "object keys that are not names are quoted" do
      tree = %Element{
        type_name: "Col",
        props: %{"label" => "c", "data" => [%{"a b" => 1, "ok" => 2, "null" => 3}]}
      }

      text = Serializer.to_source(tree, lib())
      assert text == ~s|root = Col("c", [{"a b": 1, "null": 3, ok: 2}])|
      assert summary(text).root["props"]["data"] == [%{"a b" => 1, "ok" => 2, "null" => 3}]
    end

    test "bindings and state declarations" do
      tree = %Element{
        type_name: "Input",
        props: %{"name" => "q", "value" => %Binding{target: "$q"}}
      }

      text = Serializer.to_source(tree, lib(), state: %{"$q" => "hi", "$n" => nil, "$a" => [1]})
      assert text == ~s|root = Input("q", null, $q)\n$a = [1]\n$q = "hi"|
    end

    test "strings with invalid UTF-8 do not crash the serializer" do
      tree = %Element{type_name: "Text", props: %{"text" => <<"a", 0xFF, "b">>}}
      assert is_binary(Serializer.to_source(tree, lib()))
    end
  end
end
