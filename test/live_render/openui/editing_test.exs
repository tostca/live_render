defmodule LiveRender.OpenUI.EditingTest do
  @moduledoc "Incremental editing (language.md, section 7)."

  use ExUnit.Case, async: true

  import LiveRender.OpenUI.TestHelpers

  alias LiveRender.OpenUI.Editing

  defp ids(text), do: text |> Editing.statements() |> Enum.map(& &1.id)

  defp texts(text) do
    summary(text).root["props"]["children"] |> Enum.map(& &1["props"]["text"])
  end

  test "replace, append and keep" do
    merged =
      Editing.merge(
        ~s|root = Stack([a, b])\na = Text("A")\nb = Text("B")|,
        ~s|a = Text("A2")\nroot = Stack([a, b, c])\nc = Text("C")|
      )

    assert ids(merged) == ["root", "a", "b", "c"]
    assert texts(merged) == ["A2", "B", "C"]
  end

  test "replacing keeps the original position" do
    merged = Editing.merge("x = 1\ny = 2\nz = 3", "y = 20")
    assert merged == "x = 1\ny = 20\nz = 3"
  end

  test "a patch deletes with name = null, state declarations included; GC follows" do
    existing =
      ~s|root = Stack([a, b])\n$x = 1\n$y = 2\na = Text("A")\nb = Text("B" + c)\nc = "!"|

    merged = Editing.merge(existing, "b = null\n$y = null\nroot = Stack([a])")
    assert ids(merged) == ["root", "$x", "a"]
  end

  test "$x = null in a patch deletes the declaration but leaves other uses alone" do
    merged = Editing.merge(~s|root = Stack([Text($x)])\n$x = "a"|, "$x = null")
    assert ids(merged) == ["root"]
    # The name is still used, so it is auto-declared with null.
    assert parse(merged).state == %{"$x" => nil}
  end

  test "deleting a name that does not exist is a no-op" do
    assert Editing.merge("root = Stack([])", "nope = null") == "root = Stack([])"
  end

  test "inside one program `name = null` is an ordinary binding" do
    merged = Editing.merge("root = Stack([Text(t)])\nt = null", "u = 1")
    assert "t" in ids(merged)
  end

  test "statements referenced only from Query or Mutation args are kept" do
    existing = """
    root = Stack([Metric("n", @Count(rows.items)), Button("Go", @Run(save))])
    rows = Query("list", {filter: f}, {items: []})
    f = "open"
    save = Mutation("save", {payload: p})
    p = {a: 1}
    stray = Text("x")
    """

    merged =
      Editing.merge(
        existing,
        ~s|root = Stack([Metric("n", @Count(rows.items)), Button("Go", @Run(save))])|
      )

    assert ids(merged) == ["root", "rows", "f", "save", "p"]
  end

  test "multi-line ternary statements in the program and in the patch stay whole" do
    existing =
      ~s|root = $dark\n  ? darkPage\n  : lightPage\ndarkPage = Card("Dark")\nlightPage = Card("Light")\n$dark = false|

    patch = ~s|lightPage = $big\n  ? Card("Big")\n  : Card("Small")\n$big = true|
    merged = Editing.merge(existing, patch)
    assert ids(merged) == ["root", "darkPage", "lightPage", "$dark", "$big"]
    assert merged =~ "root = $dark\n  ? darkPage\n  : lightPage"
    assert merged =~ ~s|lightPage = $big\n  ? Card("Big")\n  : Card("Small")|
    assert summary(merged).root == %{"type" => "Card", "props" => %{"title" => "Big"}}
  end

  test "a newline right after ? or : continues the statement in a patch" do
    merged =
      Editing.merge(
        ~s|root = Stack([t])\nt = Text("a")|,
        ~s|t = $x ?\n  Text("y") :\n  Text("n")|
      )

    assert ids(merged) == ["root", "t"]
    assert texts(merged) == ["n"]
  end

  test "comments in the patch are ignored" do
    patch = ~s|// replace a\na = Text("A2") # new text\n# b = null|
    merged = Editing.merge(~s|root = Stack([a, b])\na = Text("A")\nb = Text("B")|, patch)
    assert ids(merged) == ["root", "a", "b"]
    assert texts(merged) == ["A2", "B"]
    refute merged =~ "#"
  end

  test "a fenced patch with prose merges only the fenced part" do
    patch = """
    Sure, b = null is what I'd do, but here:
    ```openui
    a = Text("A2")
    ```
    And c = Text("no") is just prose.
    """

    merged = Editing.merge(~s|root = Stack([a, b])\na = Text("A")\nb = Text("B")|, patch)
    assert ids(merged) == ["root", "a", "b"]
    assert texts(merged) == ["A2", "B"]
  end

  test "a patch with several fences merges every fenced part" do
    patch = ~s|One:\n```\na = Text("A2")\n```\nTwo:\n```\nb = Text("B2")\n```|
    merged = Editing.merge(~s|root = Stack([a, b])\na = Text("A")\nb = Text("B")|, patch)
    assert texts(merged) == ["A2", "B2"]
  end

  test "a patch wrapped in message markers merges its content" do
    patch = ~s|]]>openui:content\na = Text("A2")\n]]>openui:end|
    merged = Editing.merge(~s|root = Stack([a])\na = Text("A")|, patch)
    assert texts(merged) == ["A2"]
  end

  test "without a root statement nothing is removed" do
    merged =
      Editing.merge(~s|page = Stack([a])\na = Text("A")\nx = Text("X")|, ~s|y = Text("Y")|)

    assert ids(merged) == ["page", "a", "x", "y"]
  end

  test "state declarations are kept even when nothing uses them" do
    merged =
      Editing.merge("root = Stack([])\n$unused = 1\nold = 2", ~s|root = Stack([Text("x")])|)

    assert ids(merged) == ["root", "$unused"]
  end

  test "an empty patch leaves the program unchanged" do
    assert Editing.merge("root = Stack([])\n// c", "") == "root = Stack([])\n// c"
    assert Editing.merge("root = Stack([])", "just prose") == "root = Stack([])"
  end

  test "an empty program takes the patch, without deletions" do
    assert Editing.merge("", "root = Stack([])\nx = null") == "root = Stack([])"
  end

  test "the last definition of a name wins, in program and patch" do
    merged =
      Editing.merge(
        ~s|root = Stack([t])\nt = Text("1")\nt = Text("2")|,
        ~s|u = 1\nroot = Stack([t, u2])\nu2 = Text("u")\nu2 = Text("u2")|
      )

    assert texts(merged) == ["2", "u2"]
    assert Enum.frequencies(ids(merged)) |> Map.values() |> Enum.all?(&(&1 == 1))
  end

  test "an @Each loop variable does not reach a statement of the same name" do
    existing =
      ~s|root = Stack(@Each(rows, "t", Text(t + suffix)))\nrows = ["a"]\nsuffix = "!"\nt = Text("x")|

    # Reachability is the same as for orphans: `t` is an orphan of the program.
    assert parse(existing).orphans == ["t"]
    merged = Editing.merge(existing, "z = 1")
    assert ids(merged) == ["root", "rows", "suffix"]
  end

  test "reference cycles do not hang the GC" do
    merged =
      Editing.merge(~s|root = Stack([a])\na = Card("A", [b])\nb = Card("B", [a])|, "c = 1")

    assert ids(merged) == ["root", "a", "b"]
  end

  test "a half-written patch statement is closed before merging" do
    merged = Editing.merge(~s|root = Stack([a])\na = Text("A")|, ~s|a = Text("A2|)
    assert texts(merged) == ["A2"]
  end
end
