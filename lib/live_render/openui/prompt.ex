defmodule LiveRender.OpenUI.Prompt do
  @moduledoc """
  Generates the OpenUI system prompt for a library (prompt.md, sections 4 and 5).

  The output is byte-identical to the reference `generateSystemPrompt({ library, promptOptions })`
  of `@openuidev/lang-core` for the same LibrarySpec and options (prompt.md, 4.1). The golden
  files under `test/fixtures/openui/prompts/` were rendered by the reference and pin that.

      Prompt.generate(library, tools: ToolHost.descriptors(tools), edit_mode: true)

  ## Options (prompt.md, 4.2)

    * `:tool_calls` — teach `Query`, `Mutation` and `@Run`. Defaults to true when `:tools` is
      non-empty.
    * `:bindings` — teach `$variables`, `@Set`, `@Reset` and interactive filters. Defaults to
      the value of `:tool_calls`.
    * `:builtin_functions` — list the built-in functions. Defaults to true when `:tool_calls`
      or `:bindings` is on. Library functions are listed whenever the library has any.
    * `:edit_mode` — teach editing by changed statements.
    * `:inline_mode` — teach prose plus fenced code.
    * `:tools` — tool names, or descriptors `%{name, description?, input_schema?,
      output_schema?, annotations?}` as `LiveRender.OpenUI.ToolHost.descriptors/2` returns.
      Name strings are listed before descriptors.
    * `:preamble` — replaces the opening paragraph.
    * `:examples`, `:tool_examples` — program examples; both lists are printed, in that order.
    * `:additional_rules` — lines appended at the end as `- rule`.

  Property order matters in tool schemas, because a tool's arguments print in key order. Pass
  schemas decoded with `Jason.decode!(json, objects: :ordered_objects)` to keep the order of
  the source; plain maps print their keys sorted.
  """

  alias LiveRender.OpenUI.{Builtins, Library, Signature}

  @type tool ::
          String.t()
          | %{
              required(:name) => String.t(),
              optional(:description) => String.t() | nil,
              optional(:input_schema) => map() | nil,
              optional(:output_schema) => map() | nil,
              optional(:annotations) => map() | nil
            }

  @type option ::
          {:tool_calls, boolean()}
          | {:bindings, boolean()}
          | {:builtin_functions, boolean()}
          | {:edit_mode, boolean()}
          | {:inline_mode, boolean()}
          | {:tools, [tool()]}
          | {:preamble, String.t()}
          | {:examples, [String.t()]}
          | {:tool_examples, [String.t()]}
          | {:additional_rules, [String.t()]}

  @preamble "You are an AI assistant that responds using openui-lang, a declarative UI language. Your ENTIRE response must be valid openui-lang code — no markdown, no explanations, just openui-lang."

  @action_header "## Action — Button Behavior"

  # A restricted action slot in a signature, e.g. `share?: @CopyToClipboard | @OpenUrl`
  @restricted_slot ~r/[:|] @[A-Z]/

  @doc """
  The system prompt for `library` with the given options. See the module docs for the options.
  """
  @spec generate(Library.t(), [option()]) :: String.t()
  def generate(%Library{} = lib, opts \\ []) do
    root = lib.root || "Root"
    tools = Keyword.get(opts, :tools) || []

    tool_calls = option(opts, :tool_calls, tools != [])
    bindings = option(opts, :bindings, tool_calls)
    expressions = tool_calls or bindings
    flags = %{tool_calls: tool_calls, bindings: bindings, expressions: expressions}

    components =
      Enum.map(lib.component_order, fn name ->
        c = lib.components[name]
        %{name: name, signature: Signature.for(lib, c), description: c.description}
      end)

    uses_action_expression =
      Enum.any?(components, fn c ->
        String.contains?(c.signature, "ActionExpression") or restricted_slot?(c.signature)
      end)

    custom_functions =
      Enum.map(lib.function_order, fn name -> function_line(lib, lib.functions[name]) end)

    custom_actions =
      Enum.map(lib.action_order, fn name -> "- " <> function_line(lib, lib.actions[name]) end)

    examples = (Keyword.get(opts, :examples) || []) ++ (Keyword.get(opts, :tool_examples) || [])

    # The reference joins its parts with "\n" and puts no blank line before the important rules.
    parts =
      [
        Keyword.get(opts, :preamble) || @preamble,
        "",
        syntax_rules(root, flags),
        "",
        component_signatures(lib, components, flags, uses_action_expression)
      ] ++
        functions_part(custom_functions, option(opts, :builtin_functions, expressions), flags) ++
        optional(tool_calls, fn -> ["", query_section(), "", mutation_section()] end) ++
        actions_part(custom_actions, uses_action_expression, flags) ++
        optional(tool_calls and bindings, fn -> ["", interactive_filters_section()] end) ++
        optional(tool_calls, fn -> ["", tool_workflow_section()] end) ++
        optional(tools != [], fn -> ["", tools_section(tools)] end) ++
        ["", streaming_rules(root, flags)] ++
        examples_part(examples) ++
        optional(Keyword.get(opts, :edit_mode), fn -> ["", edit_mode_section()] end) ++
        optional(Keyword.get(opts, :inline_mode), fn -> ["", inline_mode_section()] end) ++
        [important_rules(root, flags)] ++
        rules_part(Keyword.get(opts, :additional_rules) || [])

    Enum.join(parts, "\n")
  end

  defp optional(on?, _parts) when on? in [nil, false], do: []
  defp optional(_on?, parts), do: parts.()

  defp option(opts, key, default) do
    case Keyword.get(opts, key) do
      nil -> default
      value -> value
    end
  end

  defp restricted_slot?(signature), do: Regex.match?(@restricted_slot, signature)

  # Library functions get the section alone when the built-ins are not listed.
  defp functions_part(custom, true, flags), do: ["", builtin_functions_section(custom, flags)]
  defp functions_part([], _builtins?, _flags), do: []

  defp functions_part(custom, _builtins?, _flags),
    do: ["", "## Built-in Functions\n\n" <> Enum.join(custom, "\n")]

  # Library actions get the Action section alone when no component takes an action.
  defp actions_part(custom, true, flags), do: ["", action_section(flags, custom)]
  defp actions_part([], false, _flags), do: []

  defp actions_part(custom, false, _flags) do
    [
      "",
      "#{@action_header}\n\nPass one step, or Action([...]) with several steps, as a button's action.\n\nAvailable steps:\n#{Enum.join(custom, "\n")}"
    ]
  end

  defp examples_part([]), do: []
  defp examples_part(examples), do: ["", "## Examples", ""] ++ Enum.flat_map(examples, &[&1, ""])

  defp rules_part([]), do: []
  defp rules_part(rules), do: ["" | Enum.map(rules, &("- " <> &1))]

  defp function_line(lib, call), do: line("@" <> Signature.for(lib, call), call.description)

  defp line(signature, description) when description in [nil, ""], do: signature
  defp line(signature, description), do: "#{signature} — #{description}"

  # ── Sections ─────────────────────────────────────────────────────────────

  defp syntax_rules(root, flags) do
    base = [
      "## Syntax Rules",
      "",
      "1. Each statement is on its own line: `identifier = Expression`",
      "2. `root` is the entry point — every program must define `root = #{root}(...)`",
      ~s|3. Expressions are: strings ("..."), numbers, booleans (true/false), null, arrays ([...]), objects ({...}), or component calls TypeName(arg1, arg2, ...)|,
      "4. Use references for readability: define `name = ...` on one line, then use `name` later",
      "5. EVERY variable (except root) MUST be referenced by at least one other variable. Unreferenced variables are silently dropped and will NOT render. Always include defined variables in their parent's children/items array.",
      ~s|6. Arguments are POSITIONAL (order matters, not names). Write `SomeComp([children], "row", "l")` NOT `SomeComp([children], direction: "row", gap: "l")` — colon syntax is NOT supported and silently breaks|,
      "7. Optional arguments can be omitted from the end"
    ]

    binding_rules =
      if flags.bindings,
        do: [
          "Declare mutable state with `$varName = defaultValue`. Components marked with `$binding` can read/write these. Undeclared $variables are auto-created with null default."
        ],
        else: []

    expression_rules =
      if flags.expressions,
        do: [
          ~s|String concatenation: `"text" + $var + "more"`|,
          "Dot member access: `query.field` reads a field; on arrays it extracts that field from every element",
          "Index access: `arr[0]`, `data[index]`",
          "Arithmetic operators: +, -, *, /, % (work on numbers; + is string concat when either side is a string)",
          "Comparison: ==, !=, >, <, >=, <=",
          "Logical: &&, ||, ! (prefix)",
          "Ternary: `condition ? valueIfTrue : valueIfFalse`",
          "Parentheses for grouping: `(a + b) * c`"
        ],
        else: []

    numbered =
      (binding_rules ++ expression_rules)
      |> Enum.with_index(8)
      |> Enum.map(fn {rule, n} -> "#{n}. #{rule}" end)

    Enum.join(base ++ numbered ++ ["- Strings use double quotes with backslash escaping"], "\n")
  end

  defp component_signatures(lib, components, flags, uses_action_expression) do
    header = [
      "## Component Signatures",
      "",
      "Arguments marked with ? are optional. Sub-components can be inline or referenced; prefer references for better streaming."
    ]

    action_lines =
      if uses_action_expression do
        steps =
          Enum.map_join(builtin_steps(flags) ++ lib.action_order, ", ", fn
            {name, _, _, _} ->
              "@" <> name

            name ->
              "@" <> name
          end)

        [
          "Props typed `ActionExpression` accept one @step, or Action([@steps...]) for several. See the Action section for available steps (#{steps})."
        ] ++
          if Enum.any?(components, &restricted_slot?(&1.signature)),
            do: ["Props typed like `@OpenUrl | @ToAssistant` accept only the steps listed."],
            else: []
      else
        []
      end

    binding_lines =
      if flags.bindings or Enum.any?(components, &String.contains?(&1.signature, "$binding")),
        do: ["Props marked `$binding<type>` accept a `$variable` reference for two-way binding."],
        else: []

    Enum.join(header ++ action_lines ++ binding_lines ++ component_lines(lib, components), "\n")
  end

  defp component_lines(lib, components) do
    case lib.component_groups || [] do
      [] -> ["" | Enum.map(components, &component_line/1)]
      groups -> grouped_lines(groups, components)
    end
  end

  # A component listed in an earlier group is not repeated in a later one.
  defp grouped_lines(groups, components) do
    by_name = Map.new(components, &{&1.name, &1})

    {blocks, grouped} =
      Enum.map_reduce(groups, MapSet.new(), fn group, grouped ->
        members =
          (group_field(group, :components) || [])
          |> Enum.filter(&Map.has_key?(by_name, &1))
          |> Enum.uniq()
          |> Enum.reject(&MapSet.member?(grouped, &1))

        block =
          ["", "### " <> group_field(group, :name)] ++
            Enum.map(members, &component_line(by_name[&1])) ++
            (group_field(group, :notes) || [])

        {block, MapSet.union(grouped, MapSet.new(members))}
      end)

    other =
      case Enum.reject(components, &MapSet.member?(grouped, &1.name)) do
        [] -> []
        ungrouped -> ["", "### Other" | Enum.map(ungrouped, &component_line/1)]
      end

    List.flatten(blocks) ++ other
  end

  defp component_line(c), do: line(c.signature, c.description)

  defp group_field(group, key), do: Map.get(group, key, Map.get(group, Atom.to_string(key)))

  defp builtin_function_lines do
    Enum.map(Builtins.functions(), fn {_name, _params, desc, sig} -> line("@" <> sig, desc) end)
  end

  # The built-in steps the prompt lists: @Run needs tool calls, @Set and @Reset need bindings.
  defp builtin_steps(flags) do
    Enum.filter(Builtins.steps(), fn
      {"Run", _, _, _} -> flags.tool_calls
      {name, _, _, _} when name in ["Set", "Reset"] -> flags.bindings
      _ -> true
    end)
  end

  defp builtin_functions_section(custom, flags) do
    lines = Enum.join(builtin_function_lines() ++ custom, "\n")
    target = if flags.tool_calls, do: "Query results", else: "data"

    """
    ## Built-in Functions

    Data functions prefixed with `@` to distinguish from components. These are the ONLY functions available — do NOT invent new ones.
    Use @-prefixed built-in functions (@Count, @Sum, @Avg, @Min, @Max, @Round) on #{target}. Do NOT hardcode computed values.

    #{lines}

    Builtins compose — output of one is input to the next:
    `@Count(@Filter(data.rows, "field", "==", "val"))` for KPIs/chart values, `@Round(@Avg(data.rows.score), 1)`, `@Each(data.rows, "item", Comp(item.field))` for per-item rendering.
    Array pluck: `data.rows.field` extracts a field from every row → use with @Sum, @Avg, charts, tables.

    IMPORTANT @Each rule: The loop variable (e.g. "item") is ONLY available inside the @Each template expression. Always inline the template — do NOT extract it to a separate statement.
    CORRECT: `list = @Each(rows, "t", Comp(t.name))`
    WRONG: `item = Comp(t.name)` then `list = @Each(rows, "t", item)`, because t is undefined in item.
    """
    |> chomp()
  end

  defp query_section do
    """
    ## Query — Live Data Fetching

    Fetch data from available tools. Returns defaults instantly, swaps in real data when it arrives.

    ```
    metrics = Query("tool_name", {arg1: value, arg2: $binding}, {defaultField: 0, defaultData: []}, refreshInterval?)
    ```

    - First arg: tool name (string)
    - Second arg: arguments object (may reference $bindings — re-fetches automatically on change)
    - Third arg: default data (rendered immediately before fetch resolves)
    - Fourth arg (optional): refresh interval in seconds (e.g. 30 for auto-refresh every 30s)
    - Use dot access on results: metrics.totalEvents, metrics.data.day (array pluck)
    - Query results must use regular identifiers: `metrics = Query(...)`, NOT `$metrics = Query(...)`
    - Manual refresh: `Button("Refresh", Action([@Run(query1), @Run(query2)]), "secondary")` — re-fetches the listed queries
    - Refresh all queries: create Action with @Run for each query
    """
    |> chomp()
  end

  defp mutation_section do
    """
    ## Mutation — Write Operations

    Execute state-changing tool calls (create, update, delete). Unlike Query (auto-fetches on render), Mutation fires only on button click via Action.

    ```
    result = Mutation("tool_name", {arg1: $binding, arg2: "value"})
    ```

    - First arg: tool name (string)
    - Second arg: arguments object (evaluated with current $binding values at click time)
    - result.status: "idle" | "loading" | "success" | "error"
    - result.data: tool response on success
    - result.error: error message on failure
    - Mutation results use regular identifiers: `result = Mutation(...)`, NOT `$result`
    - Show loading state: `result.status == "loading" ? TextContent("Saving...") : null`
    """
    |> chomp()
  end

  defp action_section(flags, custom) do
    steps =
      Enum.map(builtin_steps(flags), fn {_name, _params, desc, sig} ->
        "- " <> line("@" <> sig, desc)
      end) ++
        custom

    mutation_example =
      if flags.tool_calls,
        do: [
          """
          Example — mutation + refresh + reset (PREFERRED pattern):
          ```
          $binding = "default"
          result = Mutation("tool_name", {field: $binding})
          data = Query("tool_name", {}, {rows: []})
          onSubmit = Action([@Run(result), @Run(data), @Reset($binding)])
          ```\
          """
        ],
        else: []

    nav_example = """
    Example — simple nav:
    ```
    viewBtn = Button("View", @OpenUrl("https://example.com"))
    ```\
    """

    rules =
      [
        ~s|- An action can be assigned to a variable or inlined: Button("Go", onSubmit) and Button("Go", Action([...])) both work|
      ] ++
        if flags.tool_calls,
          do: [
            "- If a @Run(mutation) step fails, remaining steps are skipped (halt on failure)",
            "- @Run(queryRef) re-fetches the query (fire-and-forget, cannot fail)"
          ],
          else: []

    """
    #{@action_header}

    An action wires a button click to operations. Pass one @-prefixed step bare, e.g. Button("Ask", @ToAssistant("Tell me more")). Put several steps in Action([...]), e.g. Button("Read", Action([@OpenUrl("https://example.com"), @ToAssistant("Summarize this page")])). Steps execute in order.
    Buttons without an action automatically send their label to the assistant (equivalent to @ToAssistant(label)).

    Available steps:
    #{Enum.join(steps, "\n")}

    #{Enum.join(mutation_example ++ [nav_example], "\n\n")}

    #{Enum.join(rules, "\n")}
    """
    |> chomp()
  end

  defp interactive_filters_section do
    """
    ## Interactive Filters

    To let the user filter data with a dropdown:
    1. Declare a $variable with a default: `$dateRange = "14"`
    2. Create a Select with name, items, and binding: `Select("dateRange", [SelectItem("7", "Last 7 days"), ...], null, null, $dateRange)`
    3. Wrap in FormControl for a label: `FormControl("Date Range", Select(...))`
    4. Pass $dateRange in Query args: `Query("tool", {dateRange: $dateRange}, {defaults})`
    5. When the user changes the Select, $dateRange updates and the Query automatically re-fetches

    FILTER WIRING RULE: If a $binding filter is visible in the UI, EVERY relevant Query MUST reference that $binding in its args. Never show a filter dropdown while hardcoding the query args.

    Rules for $variables:
    - $variables hold simple values (strings or numbers), NOT arrays or objects
    - $variables must be bound to a Select/Input component via the value argument (last positional arg) to be interactive
    - Queries must use regular identifiers (NOT $variables): `metrics = Query(...)` not `$metrics = Query(...)`
    - **Auto-declare**: You do NOT need to explicitly declare $variables. If you use `$foo` without declaring it, the parser auto-creates `$foo = null`. You can still declare explicitly to set a default: `$days = "14"`

    ## Forms

    Simple form — no $bindings needed. Field values are managed internally by the Form via the name prop:
    ```
    contactForm = Form("contact", submitBtn, [nameField, emailField])
    nameField = FormControl("Name", Input("name", "Your name", "text", {required: true}))
    emailField = FormControl("Email", Input("email", "your@email.com", "email", {required: true, email: true}))
    submitBtn = Button("Submit")
    ```

    Use $bindings when you need to read field values elsewhere (in Action context, Query args, or conditionals). They are auto-declared:
    ```
    $role = "engineer"
    contactForm = Form("contact", submitBtn, [nameField, emailField, roleField])
    nameField = FormControl("Name", Input("name", "Enter your name", "text", {required: true}, $name))
    emailField = FormControl("Email", Input("email", "Enter your email", "email", {required: true, email: true}, $email))
    roleField = FormControl("Role", Select("role", [SelectItem("engineer", "Engineer"), SelectItem("designer", "Designer"), SelectItem("pm", "PM")], null, {required: true}, $role))
    submitBtn = Button("Submit")
    ```

    For form + mutation patterns (create, refresh, reset), see the Action section example above.

    IMPORTANT: Always add validation rules to form fields used with Mutations. Use OBJECT syntax: {required: true, email: true, minLength: 8}. The renderer shows error messages automatically and blocks submit when validation fails.
    """
    |> chomp()
  end

  defp edit_mode_section do
    """
    ## Edit Mode

    The runtime merges by statement name: same name = replace, new name = append.
    Output ONLY statements that changed or are new. Everything else is kept automatically.

    ### Delete
    To remove a component, re-declare its parent without that component in the parent's children array. The removed component and any statements only it referenced are automatically garbage-collected.

    ### Patch size guide
    - Changing a title or label: 1 statement
    - Adding a component: 2-3 statements (the new component + parent update)
    - Removing a component: 1 statement (re-declare parent without the removed child)
    - Adding a filter + wiring to query: 3-5 statements
    - Restructuring into tabs: 5-10 statements

    ### Rules
    - Reuse existing statement names exactly — do not rename
    - Do NOT re-emit unchanged statements — the runtime keeps them
    - A typical edit patch is 1-10 statements, not 20+
    - If the existing code already satisfies the request, output only the root statement
    - NEVER output the entire program as a patch. Only output what actually changes
    - If you are about to output more than 10 statements, reconsider — most edits need fewer
    """
    |> chomp()
  end

  defp streaming_rules(root, flags) do
    steps =
      if flags.expressions do
        ["`root = #{root}(...)` — UI shell appears immediately"] ++
          ["$variable declarations — state ready for bindings"] ++
          if(flags.tool_calls,
            do: ["Query statements — defaults resolve immediately so components render with data"],
            else: []
          ) ++
          [
            "Component definitions — fill in with data already available",
            "Data values — leaf content last"
          ]
      else
        [
          "`root = #{root}(...)` — UI shell appears immediately",
          "Component definitions — fill in as they stream",
          "Data values — leaf content last"
        ]
      end
      |> Enum.with_index(1)
      |> Enum.map(fn {step, n} -> "#{n}. #{step}" end)

    """
    ## Hoisting & Streaming (CRITICAL)

    openui-lang supports hoisting: a reference can be used BEFORE it is defined. The parser resolves all references after the full input is parsed.

    During streaming, the output is re-parsed on every chunk. Undefined references are temporarily unresolved and appear once their definitions stream in. This creates a progressive top-down reveal — structure first, then data fills in.

    **Recommended statement order for optimal streaming:**
    #{Enum.join(steps, "\n")}

    Always write the root = #{root}(...) statement first so the UI shell appears immediately, even before child data has streamed in.
    """
    |> chomp()
  end

  defp inline_mode_section do
    """
    ## Inline Mode

    You are in inline mode. You can respond in two ways:

    ### 1. Code response (when the user wants to CREATE or CHANGE the UI)
    Wrap openui-lang code in triple-backtick fences. You can include explanatory text before/after:

    Here's your dashboard:

    ```openui-lang
    root = RootComp([header, content])
    header = SomeHeader("Title")
    content = SomeContent("Hello world")
    ```

    I created a simple layout with a header.

    ### 2. Text-only response (when the user asks a QUESTION)
    If the user asks "what is this?", "explain the chart", "how does this work", etc. — respond with plain text. Do NOT output any openui-lang code. The existing dashboard stays unchanged.

    ### Rules
    - When the user asks for changes, output ONLY the changed/new statements in a fenced block
    - When the user asks a question, respond with text only — NO code. The dashboard stays unchanged.
    - The parser extracts code from fences automatically. Text outside fences is shown as chat.
    """
    |> chomp()
  end

  defp tool_workflow_section do
    """
    ## Data Workflow

    When tools are available, follow this workflow:
    1. FIRST: Call the most relevant tool to inspect the real data shape before generating code
    2. Use Query() for READ operations (data that should stay live) — NEVER hardcode tool results as literal arrays or objects
    3. Use Mutation() for WRITE operations (create, update, delete) — triggered by button clicks via @Run(mutationRef)
    4. Use the real data from step 1 as condensed Query defaults (3-5 rows) so the UI renders immediately
    5. Use @-prefixed builtins (@Count, @Filter, @Sort, @Sum) on Query results for KPIs and aggregations — the runtime evaluates these live on every refresh
    6. Hardcoded arrays are ONLY for static display data (labels, options) where no tool exists

    WRONG — you called a tool and got data back, but you inlined the results:
    ```
    openCount = 2
    item1 = SomeComp("first item title")
    item2 = SomeComp("second item title")
    list = SomeList([item1, item2])
    chart = SomeChart(["A", "B"], [12, 8])
    ```
    This is static — it shows stale data and won't update. Creating item1, item2, item3... manually is ALWAYS wrong when a tool exists.

    RIGHT — use Query() for live data, Mutation() for writes, @builtins to derive values:
    ```
    data = Query("tool_name", {}, {rows: []})
    openCount = @Count(@Filter(data.rows, "field", "==", "value"))
    list = @Each(data.rows, "item", SomeComp(item.title, item.field))
    createResult = Mutation("create_tool", {title: $title})
    submitBtn = Button("Create", Action([@Run(createResult), @Run(data), @Reset($title)]))
    ```
    Everything derives from the Query — when data refreshes, the entire dashboard updates automatically.
    """
    |> chomp()
  end

  defp important_rules(root, flags) do
    verify =
      [
        "1. root = #{root}(...) is the FIRST line (for optimal streaming).",
        "2. Every referenced name is defined. Every defined name (other than root) is reachable from root."
      ] ++
        if(flags.tool_calls,
          do: ["3. Every Query result is referenced by at least one component."],
          else: []
        ) ++
        if(flags.bindings,
          do: [
            "#{if flags.tool_calls, do: "4", else: "3"}. Every $binding appears in at least one component or expression."
          ],
          else: []
        ) ++
        if(flags.tool_calls and flags.bindings,
          do: ["5. Every visible filter $binding appears in at least one Query args object."],
          else: []
        )

    """
    ## Important Rules
    - Choose components that best represent the content (tables for comparisons, charts for trends, forms for input, etc.)

    ## Final Verification
    Before finishing, walk your output and verify:
    #{Enum.join(verify, "\n")}
    """
    |> chomp()
  end

  defp chomp(text), do: String.replace_suffix(text, "\n", "")

  # ── Tools ────────────────────────────────────────────────────────────────

  defp tools_section(tools) do
    {names, specs} = Enum.split_with(tools, &is_binary/1)
    specs = Enum.map(specs, &normalize_tool/1)

    defaults =
      case Enum.reject(specs, &is_nil(&1.output_schema)) do
        [] ->
          []

        with_output ->
          [
            "",
            "### Default values for Query results",
            "",
            "Use these shapes as minimal Query defaults:"
          ] ++
            Enum.map(with_output, fn t ->
              "- #{t.name}: `#{t.output_schema |> default_for_schema() |> Jason.encode!()}`"
            end)
      end

    ([
       "## Available Tools",
       "",
       "Use these with Query() for read operations or Mutation() for write operations. The LLM decides which is appropriate based on the tool's purpose.",
       ""
     ] ++
       Enum.map(names, &("- " <> &1)) ++
       Enum.map(specs, &tool_signature/1) ++
       defaults ++
       [
         "",
         "CRITICAL: Use ONLY the tools listed above in Query() and Mutation() calls. Do NOT invent or guess tool names. If the user asks for functionality that doesn't match any available tool, use realistic mock data instead of fabricating a tool call."
       ])
    |> Enum.join("\n")
  end

  defp normalize_tool(tool) do
    get = fn atom, string -> Map.get(tool, atom, Map.get(tool, string)) end

    %{
      name: to_string(get.(:name, "name")),
      description: get.(:description, "description"),
      input_schema: get.(:input_schema, "inputSchema"),
      output_schema: get.(:output_schema, "outputSchema")
    }
  end

  defp tool_signature(tool) do
    args = fields(tool.input_schema)
    returns = if tool.output_schema, do: " → " <> type_string(tool.output_schema), else: ""
    line = "- #{tool.name}(#{args})#{returns}"
    if tool.description in [nil, ""], do: line, else: line <> "\n  " <> tool.description
  end

  defp field(name, schema, required) do
    opt = if name in required, do: "", else: "?"
    "#{name}#{opt}: #{type_string(schema)}"
  end

  # The tool argument type formatter of the reference. It differs from `Signature.type_of/2`:
  # enums only print for string types, and object fields keep their key order.
  defp type_string(schema), do: type_string(sget(schema, "type"), schema)

  defp type_string("string", schema) do
    case sget(schema, "enum") do
      values when is_list(values) -> Enum.map_join(values, " | ", &~s("#{js_string(&1)}"))
      _ -> "string"
    end
  end

  defp type_string(type, _schema) when type in ["number", "integer"], do: "number"
  defp type_string("boolean", _schema), do: "boolean"

  defp type_string("array", schema) do
    case sget(schema, "items") do
      nil -> "any[]"
      items -> type_string(items) <> "[]"
    end
  end

  defp type_string("object", schema) do
    case fields(schema) do
      "" -> "object"
      fields -> "{" <> fields <> "}"
    end
  end

  defp type_string(_type, _schema), do: "any"

  # `name: type` for each property in key order, with `?` on the optional ones.
  defp fields(schema) do
    required = required(schema)
    Enum.map_join(properties(schema), ", ", fn {k, v} -> field(k, v, required) end)
  end

  # A default-values hint for an output schema, as ordered JSON data.
  defp default_for_schema(schema) do
    case sget(schema, "type") do
      "string" ->
        ""

      type when type in ["number", "integer"] ->
        0

      "boolean" ->
        false

      "array" ->
        []

      "object" ->
        %Jason.OrderedObject{
          values: Enum.map(properties(schema), fn {k, v} -> {k, default_for_schema(v)} end)
        }

      _ ->
        nil
    end
  end

  defp js_string(v) when is_binary(v), do: v
  defp js_string(v), do: LiveRender.OpenUI.JS.to_string_value(v)

  defp sget(%Jason.OrderedObject{values: values}, key) do
    case List.keyfind(values, key, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  defp sget(map, key) when is_map(map), do: Map.get(map, key)
  defp sget(_, _), do: nil

  defp properties(schema) do
    case sget(schema, "properties") do
      %Jason.OrderedObject{values: values} -> values
      map when is_map(map) -> map |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Enum.sort()
      _ -> []
    end
  end

  defp required(schema) do
    case sget(schema, "required") do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end
end
