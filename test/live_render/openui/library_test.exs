defmodule LiveRender.OpenUI.LibraryTest do
  @moduledoc "Definition-time rules of prompt.md, section 3.1, and LibrarySpec round trips."
  use ExUnit.Case, async: true

  import LiveRender.OpenUI.Library, only: [component: 2, function: 2]

  alias LiveRender.OpenUI.{CatalogBridge, Library, StandardLibrary}

  @string %{"type" => "string"}

  test "required props must come before optional ones" do
    assert_raise ArgumentError, ~r/required prop "b" comes after an optional one/, fn ->
      Library.new(components: [component("Bad", props: [a: @string, b: @string], required: [:b])])
    end

    # A required prop with a default counts as optional, so it may come last.
    lib =
      Library.new(
        components: [
          component("Ok",
            props: [a: @string, b: Map.put(@string, "default", "x")],
            required: [:b]
          )
        ]
      )

    assert Library.component?(lib, "Ok")
  end

  test "reserved, duplicate and lowercase names are rejected" do
    assert_raise ArgumentError, ~r/reserved/, fn ->
      Library.new(components: [component("Query", [])])
    end

    assert_raise ArgumentError, ~r/reserved/, fn ->
      Library.new(functions: [function("Count", [])])
    end

    assert_raise ArgumentError, ~r/duplicate/, fn ->
      Library.new(components: [component("A", []), component("A", [])])
    end

    assert_raise ArgumentError, ~r/uppercase/, fn ->
      Library.new(components: [component("card", [])])
    end

    assert_raise ArgumentError, ~r/root/, fn ->
      Library.new(root: "Nope", components: [component("A", [])])
    end
  end

  test "the standard library and the catalog bridge follow the rules and round-trip as LibrarySpecs" do
    for lib <- [
          StandardLibrary.library(),
          CatalogBridge.library(LiveRender.StandardCatalog, root: "Stack")
        ] do
      json = lib |> Library.to_spec() |> Jason.encode!()
      again = Library.from_json(json)
      assert again.component_order == lib.component_order

      for name <- lib.component_order do
        assert Enum.map(again.components[name].params, & &1.name) ==
                 Enum.map(lib.components[name].params, & &1.name)
      end
    end
  end

  test "bindable props are read from $binding signatures when loading a spec" do
    lib = StandardLibrary.library()
    again = lib |> Library.to_spec() |> Jason.encode!() |> Library.from_json()
    assert MapSet.member?(again.components["Input"].bindable, "value")
  end
end
