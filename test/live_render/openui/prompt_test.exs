defmodule LiveRender.OpenUI.PromptTest do
  use ExUnit.Case, async: true

  alias LiveRender.OpenUI.{Library, Prompt}
  import Library, only: [component: 2, function: 2, action: 2]

  @prompts Path.expand("../../fixtures/openui/prompts", __DIR__)
  @fixture_library Path.expand("../../fixtures/openui/1.0/library.json", __DIR__)

  @option_keys %{
    "toolCalls" => :tool_calls,
    "bindings" => :bindings,
    "builtinFunctions" => :builtin_functions,
    "editMode" => :edit_mode,
    "inlineMode" => :inline_mode,
    "tools" => :tools,
    "preamble" => :preamble,
    "examples" => :examples,
    "toolExamples" => :tool_examples,
    "additionalRules" => :additional_rules
  }

  defp fixture_library, do: @fixture_library |> File.read!() |> Library.from_json()

  # ── Golden files rendered by the reference implementation ───────────────

  describe "golden prompts" do
    for dir <- @prompts |> File.ls!() |> Enum.sort(), File.dir?(Path.join(@prompts, dir)) do
      @dir dir
      test "#{dir} matches the reference byte for byte" do
        dir = Path.join(@prompts, @dir)

        input =
          dir
          |> Path.join("input.json")
          |> File.read!()
          |> Jason.decode!(objects: :ordered_objects)

        library =
          case input["library"] do
            path when is_binary(path) ->
              dir |> Path.join(path) |> File.read!() |> Jason.decode!(objects: :ordered_objects)

            spec ->
              spec
          end

        library =
          case input["libraryOverrides"] do
            nil ->
              library

            %Jason.OrderedObject{values: overrides} ->
              Enum.reduce(overrides, library, fn {k, v}, acc -> put_ordered(acc, k, v) end)
          end

        lib = Library.from_json(library)
        expected = dir |> Path.join("prompt.txt") |> File.read!()

        assert Prompt.generate(lib, options(input["promptOptions"])) == expected
      end
    end
  end

  defp put_ordered(%Jason.OrderedObject{values: values}, key, value) do
    values =
      if List.keymember?(values, key, 0),
        do: List.keystore(values, key, 0, {key, value}),
        else: values ++ [{key, value}]

    %Jason.OrderedObject{values: values}
  end

  defp options(%Jason.OrderedObject{values: values}) do
    Enum.map(values, fn
      {"tools", tools} -> {:tools, Enum.map(tools, &tool/1)}
      {key, value} -> {Map.fetch!(@option_keys, key), value}
    end)
  end

  defp tool(name) when is_binary(name), do: name

  defp tool(%Jason.OrderedObject{} = t) do
    keys = %{
      "name" => :name,
      "description" => :description,
      "inputSchema" => :input_schema,
      "outputSchema" => :output_schema,
      "annotations" => :annotations
    }

    Map.new(t.values, fn {k, v} -> {Map.fetch!(keys, k), v} end)
  end

  # ── Behavior (ported from the reference tests) ──────────────────────────

  defp card_library(opts \\ []) do
    Library.new(
      [
        root: "Card",
        components: [
          component("Card",
            description: "Root",
            props: [children: Library.children()],
            required: [:children],
            signature: "Card(children: Component[])"
          )
        ]
      ] ++ opts
    )
  end

  test "renders a local prompt from a library" do
    prompt = Prompt.generate(card_library())
    assert prompt =~ "openui-lang"
    assert prompt =~ "Card(children: Component[]) — Root"
    refute String.starts_with?(prompt, "]]>openui:config")
  end

  test "without tools, names no Query and no component outside the library" do
    prompt = Prompt.generate(card_library(), bindings: true)
    assert prompt =~ "IMPORTANT @Each rule"
    refute prompt =~ "Query"
    refute prompt =~ "Col("
  end

  test "tools turn on tool calls and bindings by default" do
    prompt = Prompt.generate(card_library(), tools: ["search"])
    assert prompt =~ "## Query — Live Data Fetching"
    assert prompt =~ "## Interactive Filters"
    assert prompt =~ "## Available Tools\n\nUse these with Query()"
    assert prompt =~ "\n- search\n"

    no_bindings = Prompt.generate(card_library(), tools: ["search"], bindings: false)
    assert no_bindings =~ "## Query — Live Data Fetching"
    refute no_bindings =~ "## Interactive Filters"
  end

  test "custom functions are listed after the generated built-in lines" do
    percent =
      function("Percent",
        description: "Formats part / total",
        params: [part: %{"type" => "number"}, total: %{"type" => "number"}],
        required: [:part],
        returns: %{"type" => "string"}
      )

    lib = card_library(functions: [percent])
    line = "@Percent(part: number, total?: number) → string — Formats part / total"

    assert Prompt.generate(lib, tool_calls: true) =~
             "@Sum(numbers: number[]) → number — Sum of numeric array"

    assert Prompt.generate(lib, tool_calls: true) =~
             "@Each(array: any[], varName: string, template: any) — Evaluate template for each element. varName is the loop variable — use it ONLY inside the template expression (inline). Do NOT create a separate statement for the template.\n#{line}"

    assert Prompt.generate(lib) =~ "## Built-in Functions\n\n#{line}"
    refute Prompt.generate(card_library(), tool_calls: true) =~ "@Percent"

    refute Prompt.generate(card_library(), tool_calls: true, builtin_functions: false) =~
             "## Built-in Functions"
  end

  test "a custom action in a restricted slot prints with its @ name" do
    copy =
      action("CopyToClipboard",
        description: "Copies text to the clipboard",
        params: [text: %{"type" => "string"}],
        required: [:text]
      )

    lib =
      Library.new(
        root: "Share",
        components: [
          component("Share",
            props: [share: Library.action_prop(["CopyToClipboard", "OpenUrl"])],
            required: [:share]
          )
        ],
        actions: [copy]
      )

    prompt = Prompt.generate(lib)
    assert prompt =~ "\nShare(share: @CopyToClipboard | @OpenUrl)\n"
    assert prompt =~ "Props typed like `@OpenUrl | @ToAssistant` accept only the steps listed."
    assert prompt =~ "(@ToAssistant, @OpenUrl, @CopyToClipboard)"
  end

  test "custom actions add exactly their step lines to the prompt" do
    step = "\n- @CopyToClipboard(text: string) — Copies text to the clipboard"

    copy =
      action("CopyToClipboard",
        description: "Copies text to the clipboard",
        params: [text: %{"type" => "string"}],
        required: [:text]
      )

    prompt = fn actions ->
      Library.new(
        root: "ActionButton",
        components: [
          component("ActionButton",
            props: [label: %{"type" => "string"}, action: Library.action_prop()],
            required: [:label, :action]
          )
        ],
        actions: actions
      )
      |> Prompt.generate()
    end

    with_copy = prompt.([copy])
    assert with_copy =~ step

    assert with_copy |> String.replace(step, "") |> String.replace(", @CopyToClipboard)", ")") ==
             prompt.([])
  end

  test "derived signatures carry $binding markers and component descriptions" do
    lib =
      Library.new(
        root: "Input",
        components: [
          component("Input",
            description: "A text field",
            props: [name: %{"type" => "string"}, value: %{"type" => "string"}],
            required: [:name],
            bindable: [:value]
          )
        ]
      )

    prompt = Prompt.generate(lib)
    assert prompt =~ "\nInput(name: string, value?: $binding<string>) — A text field\n"

    assert prompt =~
             "Props marked `$binding<type>` accept a `$variable` reference for two-way binding."
  end

  test "groups split components, with ungrouped ones under Other" do
    lib =
      Library.new(
        root: "A",
        component_groups: [%{name: "First", components: ["B"], notes: ["- note"]}],
        components: [
          component("A", props: [x: %{"type" => "string"}]),
          component("B", props: [y: %{"type" => "number"}], description: "Bee")
        ]
      )

    prompt = Prompt.generate(lib)
    assert prompt =~ "\n\n### First\nB(y?: number) — Bee\n- note\n\n### Other\nA(x?: string)\n"
  end

  test "the same inputs give the same prompt" do
    lib = fixture_library()
    opts = [tools: ["a", %{name: "b", input_schema: %{"type" => "object"}}], edit_mode: true]
    assert Prompt.generate(lib, opts) == Prompt.generate(fixture_library(), opts)
  end

  test "plain-map tool schemas print their properties in sorted key order" do
    tool = %{
      name: "find",
      description: nil,
      input_schema: %{
        "type" => "object",
        "properties" => %{"zeta" => %{"type" => "string"}, "alpha" => %{"type" => "integer"}},
        "required" => ["zeta"]
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{"b" => %{"type" => "array"}, "a" => %{"type" => "boolean"}}
      }
    }

    prompt = Prompt.generate(card_library(), tools: [tool])
    assert prompt =~ "\n- find(alpha?: number, zeta: string) → {a?: boolean, b?: any[]}\n"
    assert prompt =~ ~s(\n- find: `{"a":false,"b":[]}`\n)
  end

  test "accepts the descriptors ToolHost returns" do
    descriptors = LiveRender.OpenUI.ToolHost.descriptors(%{"listTickets" => fn _ -> [] end})
    assert Prompt.generate(card_library(), tools: descriptors) =~ "\n- listTickets()\n"
  end

  # ── LibrarySpec output ──────────────────────────────────────────────────

  test "to_spec keeps the signatures given in the spec" do
    source = @fixture_library |> File.read!() |> Jason.decode!()
    json = fixture_library() |> Library.to_spec() |> Jason.encode!()
    spec = Jason.decode!(json)

    for section <- ["components", "functions", "actions"] do
      signatures = fn doc -> Map.new(doc[section], fn {name, e} -> {name, e["signature"]} end) end
      assert signatures.(spec) == signatures.(source)
    end

    # The re-loaded spec gives the same prompt, so component order survives the round trip.
    assert json |> Library.from_json() |> Prompt.generate() ==
             Prompt.generate(fixture_library())
  end
end
