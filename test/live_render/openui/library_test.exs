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

  describe "nested object fields" do
    defp option_lib(properties) do
      Library.new(
        root: "Pick",
        components: [
          component("Pick",
            props: [
              options: %{
                "type" => "array",
                "items" => %{"type" => "object", "properties" => properties}
              }
            ],
            required: [:options]
          )
        ]
      )
    end

    defp pick_line(lib) do
      lib
      |> LiveRender.OpenUI.Prompt.generate()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "Pick("))
    end

    test "print in declaration order when the properties are ordered" do
      props = Jason.OrderedObject.new([{"value", @string}, {"label", @string}])
      assert pick_line(option_lib(props)) == "Pick(options: {value?: string, label?: string}[])"
    end

    test "keep their order through a LibrarySpec round trip" do
      props = Jason.OrderedObject.new([{"value", @string}, {"label", @string}])
      again = props |> option_lib() |> Library.to_spec() |> Jason.encode!() |> Library.from_json()
      assert pick_line(again) == "Pick(options: {value?: string, label?: string}[])"
    end

    test "are sorted when the properties are a plain map, which has no order" do
      props = %{"value" => @string, "label" => @string}
      assert pick_line(option_lib(props)) == "Pick(options: {label?: string, value?: string}[])"
    end

    test "an object without properties prints as object" do
      assert pick_line(option_lib(%{})) == "Pick(options: object[])"
    end
  end
end
