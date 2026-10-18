defmodule LiveRender.OpenUI.StreamingTest do
  @moduledoc """
  Streaming (language.md, section 4). The central property: whatever the chunking, the result at
  stream end equals a batch parse of the joined text.
  """

  use ExUnit.Case, async: true

  import LiveRender.OpenUI.TestHelpers

  alias LiveRender.OpenUI.Conformance
  alias LiveRender.OpenUI.Parser.Stream

  @extra_programs [
    # Multi-line ternaries in every continuation form.
    "$n = 0\nroot = Stack([Text(s)])\ns = $n > 0\n  ? \"some\"\n  : \"none\"\nt = Text(\"x\")\n",
    "root = Stack([Text(s)])\ns = $a ?\n  \"yes\" :\n  \"no\"\n",
    "root = Stack([Text(s)])\ns = $a\n  ? $b\n    ? \"ab\"\n    : \"a\"\n  : \"none\"\nz = 1",
    "root = Stack([Text(s)])\ns = $a ? \"x\"\n\n  : \"y\"\n",
    # Strings holding newlines, comment markers and fence-looking text.
    "root = Stack([Text(a), Text(b)])\na = \"line one\nline // two # three\"\nb = 'it''s # not // a comment'\n",
    "root = Stack([Text(a)]) // trailing comment\n# a full comment line\na = \"```not a fence```\" # comment\n",
    "root = Stack([Text(\"tab\\there \\u00e9 \\ud83d\\ude00 émoji 😀 中文\")])\n",
    # A fence that arrives late, with prose before and after.
    "Sure, here it is:\n```openui\nroot = Stack([Text(\"a\"), b])\nb = Text(\"b\")\n```\nHope that helps.\n",
    "Text with a 'quote and \"quote\n```\nroot = Stack([Text(\"in ``` string\")])\n```\n",
    "One:\n```\nroot = Stack([a])\n```\nTwo:\n```\na = Text(\"A\")\n```\n",
    # Message markers.
    "]]>openui:content?library=fixtures%401.0.0\nroot = Stack([Text(\"m\")])\n]]>openui:context\n{\"a\":1}\n]]>openui:end\n",
    "]]>openui:content\nroot = Stack([Text(\"old\")])\ncut]]>openui:content\nroot = Stack([Text(\"new\")])\n]]>openui:end",
    # Redefinitions, unresolved references, state, queries and errors.
    "root = Stack([t, missing, u])\nt = Text(\"first\")\nt = Text(\"second\")\nu = Tag(\"x\", \"purple\")\n",
    "$q = \"\"\nroot = Stack([Input(\"q\", \"Search\", $q), Metric(\"n\", @Count(rows.items))])\nrows = Query(\"list\", {q: $q}, {items: [1, 2]})\n",
    "root = Stack([Text(\"a\"), Chart(1), null, missing, Card(\"T\", Text(\"bare\"))])",
    "root = Card(\"Title\", [Text($dishes), Text($dish)])\n$dish = \"soup\"\n",
    "root = Stack([Text(\"a\" + -1 + (2 - -3) * 4 % 3)])\nx = [1 -2, a.b.0, m[0][\"k\"]]\n",
    "root = Stack(@Each([\"a\", \"b\"], \"t\", Button(t, @Set($sel, t))))\n",
    "  \r\nroot = Stack([Text(\"crlf\")])\r\nt = Text(\"x\")\r\n",
    "root = Stack([x])\ny = [1, 2)\nx = Text(\"enum\", \"bogus\")\n",
    "root = Stack([Text(\"unterminated"
  ]

  defp programs do
    fixtures =
      Path.wildcard(Path.join(Conformance.root(), "**/input.oui"))
      |> Enum.sort()
      |> Enum.map(&{Path.relative_to(&1, Conformance.root()), File.read!(&1)})

    chunked =
      Path.wildcard(Path.join(Conformance.root(), "**/chunks.json"))
      |> Enum.sort()
      |> Enum.map(
        &{Path.relative_to(&1, Conformance.root()),
         &1 |> File.read!() |> Jason.decode!() |> Enum.join()}
      )

    extra = @extra_programs |> Enum.with_index() |> Enum.map(fn {p, i} -> {"extra #{i}", p} end)
    fixtures ++ chunked ++ extra
  end

  defp assert_stream_equals_batch(name, chunks, lib) do
    text = IO.iodata_to_binary(chunks)
    want = canonical(parse(text, lib), lib)
    got = canonical(stream(chunks, lib), lib)

    assert got == want, """
    streaming differs from batch for #{name}
    chunks: #{inspect(chunks)}
    batch:  #{inspect(want)}
    stream: #{inspect(got)}
    """
  end

  describe "streaming equals parsing" do
    test "every two-chunk split of every program" do
      lib = lib()

      for {name, text} <- programs(), at <- 0..byte_size(text) do
        # Chunks are binaries, so a split may fall inside a multi-byte character.
        chunks = [binary_part(text, 0, at), binary_part(text, at, byte_size(text) - at)]
        assert_stream_equals_batch(name, chunks, lib)
      end
    end

    test "random splits into three to five chunks" do
      lib = lib()
      :rand.seed(:exsss, {7, 11, 13})

      for {name, text} <- programs(), _ <- 1..25, byte_size(text) > 4 do
        n = Enum.random(3..5)

        cuts =
          1..(byte_size(text) - 1)
          |> Enum.take_random(n - 1)
          |> Enum.sort()

        {chunks, last} =
          Enum.reduce(cuts, {[], 0}, fn cut, {acc, from} ->
            {[binary_part(text, from, cut - from) | acc], cut}
          end)

        chunks = Enum.reverse([binary_part(text, last, byte_size(text) - last) | chunks])
        assert_stream_equals_batch(name, chunks, lib)
      end
    end

    test "byte-at-a-time streaming" do
      lib = lib()

      for {name, text} <- programs() do
        chunks = for <<b <- text>>, do: <<b>>
        assert_stream_equals_batch(name, chunks, lib)
      end
    end

    test "Stream.set with the growing text equals parsing" do
      lib = lib()

      for {name, text} <- programs() do
        {s, _} =
          Enum.reduce(1..byte_size(text)//7, {Stream.new(lib), nil}, fn n, {s, _} ->
            Stream.set(s, binary_part(text, 0, n))
          end)

        {_s, final} = Stream.set(s, text, true)
        assert canonical(final, lib) == canonical(parse(text, lib), lib), name
      end
    end
  end

  describe "mid-stream results" do
    test "a pending statement that needed closing never replaces a completed one" do
      s = Stream.new(lib())
      {s, r1} = Stream.push(s, "root = Stack([t])\nt = Text(\"done\")\nx = 1\nt = Text(\"half")
      assert canonical(r1).root["props"]["children"] == [text("done")]

      # Still pending and still incomplete: the completed definition stays.
      {s, r2} = Stream.push(s, " way")
      assert canonical(r2).root["props"]["children"] == [text("done")]

      # Closed by its own text, the redefinition is no longer pending-with-closing and wins.
      {s, r3} = Stream.push(s, "\")")
      assert canonical(r3).root["props"]["children"] == [text("half way")]

      {_s, final} = Stream.finish(s)
      assert canonical(final).root["props"]["children"] == [text("half way")]
    end

    test "at stream end a pending redefinition that needed closing wins (rule 7)" do
      s = Stream.new(lib())
      {s, _} = Stream.push(s, "root = Stack([t])\nt = Text(\"done\")\nt = Text(\"cut")
      {_s, final} = Stream.finish(s)
      assert canonical(final).root["props"]["children"] == [text("cut")]
      assert final.incomplete
    end

    test "unresolved array elements are left out while streaming" do
      s = Stream.new(lib())
      {s, r} = Stream.push(s, "root = Stack([a, b, c])\na = Text(\"A\")\nc = Text(\"C\")\nb = Te")
      # `b` is pending as the reference `Te`, which is unresolved.
      assert canonical(r).root["props"]["children"] == [text("A"), text("C")]
      assert canonical(r).errors == []

      {s, r} = Stream.push(s, "xt(\"B\"")
      assert canonical(r).root["props"]["children"] == [text("A"), text("B"), text("C")]

      {_s, final} = Stream.finish(s)
      assert canonical(final).root["props"]["children"] == [text("A"), text("B"), text("C")]
    end

    test "a growing $name at the end of the buffer is not auto-declared" do
      s = Stream.new(lib())
      {s, r} = Stream.push(s, "root = Stack([Text($d")
      refute Map.has_key?(r.state, "$d")

      {s, r} = Stream.push(s, "ishes")
      refute Map.has_key?(r.state, "$dishes")
      refute Map.has_key?(r.state, "$d")

      {s, r} = Stream.push(s, ")])")
      assert Map.has_key?(r.state, "$dishes")

      {_s, final} = Stream.finish(s)
      assert final.state == %{"$dishes" => nil}
    end

    test "a $name that already appears in full earlier is declared even at the end" do
      s = Stream.new(lib())
      {_s, r} = Stream.push(s, "root = Stack([Text($a), Text($a")
      assert Map.has_key?(r.state, "$a")
    end

    test "at stream end a trailing $name is declared" do
      final = stream(["root = Stack([Text($tail"])
      assert Map.has_key?(final.state, "$tail")
    end

    test "a completed statement is never re-parsed mid-stream" do
      s = Stream.new(lib())
      {s, _} = Stream.push(s, "root = Stack([a])\na = Text(\"A\")\nb = 1")
      assert s.completed_end > 0
      assert Enum.map(s.completed, & &1.id) == ["root", "a"]
      {s2, _} = Stream.push(s, "2")
      assert s2.completed == s.completed
    end

    test "a statement is not complete until the next line shows it cannot continue" do
      s = Stream.new(lib())
      {s, _} = Stream.push(s, "root = Stack([Text(v)])\nv = $a\n")
      # The newline arrived, but the next line might start with `?`.
      assert Enum.map(s.completed, & &1.id) == ["root"]

      {s, r} = Stream.push(s, "  ? \"yes\"\n  : \"no\"\n")
      assert Enum.map(s.completed, & &1.id) == ["root"]
      assert canonical(r).root["props"]["children"] == [text("no")]

      {s, _} = Stream.push(s, "w")
      assert Enum.map(s.completed, & &1.id) == ["root", "v"]
    end

    test "reconciliation: a fence opener arriving discards the cache" do
      s = Stream.new(lib())
      {s, r} = Stream.push(s, "intro = 1\nroot = Stack([Text(\"prose\")])\n")
      assert canonical(r).root

      {s, r} = Stream.push(s, "```\nroot = Stack([Text(\"fenced\")])\n")
      assert canonical(r).root["props"]["children"] == [text("fenced")]
      assert Enum.map(s.completed, & &1.id) == []

      {_s, final} = Stream.finish(s)
      assert canonical(final).root["props"]["children"] == [text("fenced")]
      refute Enum.any?(final.statements, &(&1.id == "intro"))
    end

    test "every intermediate frame of the worked example is free of errors and placeholders" do
      chunks =
        Path.join(Conformance.root(), "streaming/001-worked-example/chunks.json")
        |> File.read!()
        |> Jason.decode!()

      Enum.reduce(chunks, Stream.new(lib()), fn chunk, s ->
        {s, r} = Stream.push(s, chunk)
        summary = canonical(r)
        refute Enum.any?(summary.errors, &(&1["code"] != "no-root"))
        refute inspect(summary.root) =~ "nil"
        s
      end)
    end

    test "an empty stream and a whitespace-only stream give an empty result" do
      assert %{root: nil, statements: []} = stream([])
      assert %{root: nil, statements: []} = stream(["  \n", "\t"])
    end

    test "a stream ended mid-escape closes the string and keeps the text" do
      final = stream(["root = Stack([t])\nt = Text(\"a", "\\"])
      assert canonical(final).root["props"]["children"] == [text("a\\")]
      assert final.incomplete
    end

    test "incomplete covers the whole text, not only the pending tail" do
      # The `)` does not close `[`, so the text ends inside an unclosed bracket. While incomplete,
      # enum checks wait, so the bad variant is not reported in either mode.
      text = "root = Stack([x])\ny = [1, 2)\nx = Text(\"enum\", \"bogus\")\n"
      batch = parse(text)
      assert batch.incomplete
      assert stream([text]).incomplete
      assert canonical(stream([text])) == canonical(batch)
      assert canonical(batch).errors == []
    end
  end

  defp text(t), do: %{"type" => "Text", "props" => %{"text" => t}}
end
