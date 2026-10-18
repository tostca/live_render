defmodule LiveRender.OpenUI.StatementsTest do
  @moduledoc "Source text preparation and statement boundaries (language.md, sections 1.2 and 1.4)."

  use ExUnit.Case, async: true

  import LiveRender.OpenUI.TestHelpers

  alias LiveRender.OpenUI.{Editing, Lexer, Source, Statements}

  # [{id, source}] as the parser splits the text.
  defp split(text) do
    prepared = Source.prepare(text)

    prepared
    |> Lexer.tokenize()
    |> Statements.split()
    |> Enum.map(fn raw ->
      stop = raw.stop || byte_size(prepared)
      {raw.id, prepared |> binary_part(raw.start, stop - raw.start) |> String.trim()}
    end)
  end

  defp ids(text), do: text |> split() |> Enum.map(&elem(&1, 0))

  describe "statement shape" do
    test "lines without `name =` are skipped" do
      text = """
      hello world
      root = Stack([])
      = 5
      5 = 3
      "s" = 1
      Foo = Text("a")
      $s = 1
      @f = 2
      a.b = 3
      x == 1
      y =
      z = 1
      """

      assert ids(text) == ["root", "Foo", "$s", "z"]
    end

    test "a statement with an empty right side produces nothing" do
      assert ids("a =\nb = 1") == ["b"]
      assert ids("a = // comment\nb = 1") == ["b"]
    end

    test "a skipped line does not swallow the next statement" do
      assert ids("oops ( [ {\nroot = Stack([])") == ["root"]
    end
  end

  describe "brackets" do
    test "newlines inside brackets continue the statement" do
      text = ~s|root = Stack([\n  a,\n  b\n])\na = Text(\n"A"\n)\nb = {\n k: 1\n}|

      assert split(text) == [
               {"root", "root = Stack([\n  a,\n  b\n])"},
               {"a", ~s|a = Text(\n"A"\n)|},
               {"b", "b = {\n k: 1\n}"}
             ]
    end

    test "strings hold raw newlines" do
      assert ids(~s(a = "one\ntwo = 2\nthree"\nb = 'x\ny = 1'\nc = 1)) == ["a", "b", "c"]
    end

    test "an extra closing bracket does not go below depth zero" do
      assert ids("a = 1)\nb = 2") == ["a", "b"]
    end
  end

  describe "ternary continuation" do
    test "`?` on the next line" do
      assert split(~s|s = $n > 0\n  ? "some"\n  : "none"\nt = 1|) == [
               {"s", ~s|s = $n > 0\n  ? "some"\n  : "none"|},
               {"t", "t = 1"}
             ]
    end

    test "`?` after blank lines still continues" do
      assert ids("s = c\n\n\n  ? 1 : 2\nt = 1") == ["s", "t"]
    end

    test "`:` on the next line" do
      assert ids("s = c ? 1\n  : 2\nt = 1") == ["s", "t"]
    end

    test "newline right after `?` with an empty branch" do
      assert ids("s = c ?\n 1 : 2\nt = 1") == ["s", "t"]
      assert ids("s = c ?\n\n 1\n :\n 2\nt = 1") == ["s", "t"]
    end

    test "newline right after `:` with an empty branch" do
      assert ids("s = c ? 1 :\n 2\nt = 1") == ["s", "t"]
    end

    test "a branch that is only a prefix operator is still empty" do
      assert ids("s = c ? 1 : -\n2\nt = 1") == ["s", "t"]
      assert ids("s = c ? 1 : !\nx\nt = 1") == ["s", "t"]
    end

    test "nested ternaries" do
      text = ~s|s = $a\n  ? $b\n    ? "ab"\n    : "a"\n  : "none"\nt = 1|
      assert ids(text) == ["s", "t"]
      assert ids("s = a ? b ? 1 : 2\n : 3\nt = 1") == ["s", "t"]
      assert ids("s = a ? 1 : b ?\n 2 : 3\nt = 1") == ["s", "t"]
    end

    test "the ternary closes at the first complete operand after its `:`" do
      # After `: 2` the ternary is closed, so the newline ends the statement.
      assert ids("s = c ? 1 : 2\nt = 1") == ["s", "t"]
      assert ids(~s|s = c ? 1 : Text("x")\nt = 1|) == ["s", "t"]
      assert ids("s = c ? 1 : (2\n+ 3)\nt = 1") == ["s", "t"]
    end

    test "a `?` on the line after a complete ternary continues it" do
      assert ids("s = c ? 1 : 2\n? 3 : 4\nt = 1") == ["s", "t"]
    end

    test "an open ternary with no `:` runs on" do
      assert ids("s = c ? 1\nt = 2") == ["s"]
    end

    test "`?` and `:` inside brackets do not count" do
      assert ids("s = {a: 1}\nt = [c ? 1 : 2]\nu = 1") == ["s", "t", "u"]
    end

    test "the ternary parses to the same tree on one line or several" do
      one = parse(~s|$n = 1\nroot = Stack([Text(s)])\ns = $n > 0 ? "some" : "none"|)

      many =
        parse(~s|$n = 1\nroot = Stack([Text(s)])\ns = $n > 0\n  ?\n  "some"\n  :\n  "none"|)

      assert canonical(one) == canonical(many)

      assert canonical(many).root["props"]["children"] == [
               %{"type" => "Text", "props" => %{"text" => "some"}}
             ]
    end
  end

  describe "the batch parser, the stream and the edit merge agree" do
    @programs [
      ~s|s = $n > 0\n  ? "some"\n  : "none"\nt = Text("x")|,
      "s = c ?\n 1 :\n 2\nt = 1",
      ~s|a = [1,\n2]\nb = "x\ny"\nc = c ? 1\n : 2|,
      ~s|page = Stack([a])\na = $x\n  ? Text("y")\n  : Text("n")|
    ]

    test "edit merge keeps every statement whole" do
      for text <- @programs do
        merged = Editing.merge(text, "zzz = 1")
        assert split(merged) == split(text) ++ [{"zzz", "zzz = 1"}], text
      end
    end
  end

  describe "fence extraction" do
    test "text without fences is used as is" do
      assert Source.prepare("a = 1") == "a = 1"
    end

    test "only the fenced parts are kept, joined with newlines" do
      text = "Intro a = 1\n```openui\nb = 2\n```\nmiddle c = 3\n```\nd = 4\n```\nOutro"
      assert Source.prepare(text) == "b = 2\n\nd = 4"
    end

    test "a fence opens only at the start of a line" do
      assert Source.prepare("x ```\na = 1") == "x ```\na = 1"
      assert Source.prepare("  ```\na = 1\n```") == "a = 1"
    end

    test "an unterminated fence runs to the end" do
      assert Source.prepare("prose\n```\na = 1\nb = 2") == "a = 1\nb = 2"
    end

    test "a fence opener whose line has not ended yet is empty" do
      assert Source.prepare("prose\n```open") == ""
    end

    test "backticks in double-quoted strings do not close a fence" do
      assert Source.prepare(~s|```\na = "x ``` y"\n```|) == ~s|a = "x ``` y"|
    end

    test "single quotes do not shield backticks" do
      assert Source.prepare("```\na = 'x ``` y'\n```") == "a = 'x"
    end

    test "quotes in prose outside fences do not shield anything" do
      assert Source.prepare(~s|It's "open\n```\na = 1\n```|) == "a = 1"
    end

    test "backticks inside comments count, since comments are stripped after extraction" do
      assert Source.prepare("```\na = 1 // ``` closes\nb = 2\n```") == "a = 1"
    end
  end

  describe "comment stripping" do
    test "// and # run to the end of the line" do
      assert Source.prepare("a = 1 // one\n# full line\nb = 2 # two") == "a = 1\n\nb = 2"
    end

    test "markers in strings are kept, even in multi-line strings" do
      text = ~s|a = "x // y\nz # w" // real\nb = 'q # r'|
      assert Source.prepare(text) == ~s|a = "x // y\nz # w"\nb = 'q # r'|
    end

    test "escaped quotes do not end a string" do
      assert Source.prepare(~S(a = "x \" // y" # c)) == ~S(a = "x \" // y")
    end

    test "a single / is division" do
      assert ev("6 / 3 // half") == 2
    end
  end

  describe "trimming" do
    test "leading and trailing whitespace is removed" do
      assert Source.prepare("  \n\t a = 1 \n\n ") == "a = 1"
    end
  end

  describe "implicit closing" do
    test "strings, then brackets in reverse order" do
      assert Source.auto_close(~s|a = Stack([Text("x|) == {~s|a = Stack([Text("x")])|, true}
      assert Source.auto_close("a = {k: [1") == {"a = {k: [1]}", true}
      assert Source.auto_close("a = 'x") == {"a = 'x'", true}
    end

    test "a text ending mid-escape gets a backslash first" do
      assert Source.auto_close(~s(a = "x\\)) == {~s(a = "x\\\\"), true}
    end

    test "a closing bracket that does not match is skipped and leaves the stack alone" do
      assert Source.auto_close("a = [1)") == {"a = [1)]", true}
      assert Source.auto_close("a = (1]") == {"a = (1])", true}
    end

    test "complete text is unchanged" do
      assert Source.auto_close(~s|a = [1, "("]|) == {~s|a = [1, "("]|, false}
    end
  end
end
