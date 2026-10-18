defmodule LiveRender.OpenUI.TreeTest do
  @moduledoc "Tree paths and form scopes (language.md, section 5.3)."

  use ExUnit.Case, async: true

  alias LiveRender.OpenUI.{Conformance, Element, Runtime, Tree, Values}

  setup_all do
    lib = Conformance.library()

    rt =
      Runtime.new(lib,
        response: """
        root = Stack([Card("c", [a, Form("f", [b, Stack([c])])]), Form("", [d])])
        a = Input("a", "A")
        b = Input("b", "B")
        c = Button("C")
        d = Input("d", "D")
        """
      )

    %{lib: lib, tree: Runtime.tree(rt)}
  end

  test "elements lists every element depth first with its path and form", %{lib: lib, tree: tree} do
    rows =
      for {%Element{} = el, path, form} <- Tree.elements(tree, lib),
          do: {el.statement_id || el.type_name, path, form}

    assert rows == [
             {"root", [], nil},
             {"Card", ["children", 0], nil},
             {"a", ["children", 0, "children", 0], nil},
             {"Form", ["children", 0, "children", 1], "f"},
             {"b", ["children", 0, "children", 1, "children", 0], "f"},
             {"Stack", ["children", 0, "children", 1, "children", 1], "f"},
             {"c", ["children", 0, "children", 1, "children", 1, "children", 0], "f"},
             # A form with an empty name gives no scope.
             {"Form", ["children", 1], nil},
             {"d", ["children", 1, "children", 0], nil}
           ]
  end

  test "at_path finds each element with its form", %{lib: lib, tree: tree} do
    for {el, path, form} <- Tree.elements(tree, lib) do
      assert Tree.at_path(tree, lib, path) == {:ok, el, form}
    end
  end

  test "at_path rejects paths that do not lead to an element", %{lib: lib, tree: tree} do
    for path <- [
          ["children", 9],
          ["nope"],
          [0],
          ["children", -1],
          ["children", 0, "title"],
          ["children", 0, "title", 0],
          ["children", "0"]
        ] do
      assert Tree.at_path(tree, lib, path) == :error, inspect(path)
    end

    assert Tree.at_path(nil, lib, []) == :error
    assert Tree.at_path(tree, lib, "children.0") == :error
  end

  test "find_statement returns the first element from a statement", %{lib: lib, tree: tree} do
    assert {:ok, %Element{type_name: "Button"}, path, "f"} = Tree.find_statement(tree, lib, "c")
    assert {:ok, _, ^path, _} = Tree.find_statement(tree, lib, "c")
    assert Tree.find_statement(tree, lib, "missing") == :error
  end

  test "paths round-trip through encode and decode" do
    path = ["children", 0, "children", 12, "items", 3]
    assert path |> Tree.encode_path() |> Tree.decode_path() == {:ok, path}
    assert Tree.decode_path("") == {:ok, []}
    assert Tree.decode_path("children.-1") == {:ok, ["children", "-1"]}
    assert Tree.decode_path(String.duplicate("a.", 1100)) == :error
    assert Tree.decode_path(nil) == :error
  end

  describe "Values.from_host" do
    test "normalizes host data to OpenUI values" do
      assert Values.from_host(%{:a => [1.0, :b, {1, 2}], "c" => nil, :d => true}) ==
               %{"a" => [1, "b", [1, 2]], "c" => nil, "d" => true}

      assert Values.from_host(~D[2026-01-02]) == "2026-01-02"
      assert Values.from_host(%URI{host: "x"})["host"] == "x"
    end

    test "never crashes on keys or values with no string form" do
      assert %{} = Values.from_host(%{{1, 2} => 1, 3 => 2})
      assert is_binary(Values.from_host(self()))
    end
  end
end
