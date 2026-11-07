defmodule LiveRender.OpenUI.Library do
  @moduledoc """
  A compiled OpenUI LibrarySpec (prompt.md, section 2).

  The positional order of a component's arguments is the key order of its `properties`. Elixir
  maps do not keep key order, so a library stores every parameter list as an ordered list, and
  `from_json/2` decodes JSON with ordered objects.

  Build a library in Elixir:

      Library.new(
        id: "support",
        root: "Card",
        components: [
          component("Card",
            description: "A titled container",
            props: [title: %{"type" => "string"}, children: Library.children()],
            required: [:title],
            renderer: &MyComponents.card/1
          ),
          component("Input",
            props: [name: %{"type" => "string"}, value: %{"type" => "string"}],
            required: [:name],
            bindable: [:value],
            field: "input"
          )
        ],
        functions: [
          function("Upper",
            params: [text: %{"type" => "string"}],
            required: [:text],
            returns: %{"type" => "string"},
            impl: fn %{"text" => t} -> String.upcase(t) end
          )
        ],
        actions: [action("CopyToClipboard", params: [text: %{"type" => "string"}], required: [:text])]
      )

  or load a LibrarySpec JSON document with `from_json/2` and attach implementations with the
  `:functions`, `:renderers`, `:forms` and `:fields` options.

  Component options that are not part of the LibrarySpec, because they are platform behavior
  (prompt.md, section 2.6):

    * `:renderer` — a function component `(assigns -> rendered)`, or a module with `render/1`
    * `:form` — the prop that names a form scope, e.g. `"name"` for `Form(name, children)`
    * `:field` — the `componentType` this component writes into form state, e.g. `"input"`
    * `:value_prop`, `:rules_prop` — the props a field reads its value and validation rules from
  """

  alias LiveRender.OpenUI.Builtins

  defmodule Param do
    @moduledoc "One positional parameter of a component, function or action."
    defstruct [:name, required: false, default: :none, schema: %{}, check: nil]

    @typedoc """
    `schema` is the parameter's JSON Schema as the library wrote it. `check` is the same schema
    with action `$ref`s inlined, which is what validation reads.
    """
    @type t :: %__MODULE__{
            name: String.t(),
            required: boolean(),
            default: :none | {:ok, term()},
            schema: map(),
            check: map() | nil
          }
  end

  defmodule Component do
    @moduledoc "A library component."
    defstruct [
      :name,
      description: "",
      params: [],
      signature: nil,
      bindable: MapSet.new(),
      renderer: nil,
      form: nil,
      field: nil,
      value_prop: "value",
      rules_prop: "rules",
      name_prop: "name",
      schema: %{}
    ]

    @type t :: %__MODULE__{}
  end

  defmodule Call do
    @moduledoc "A library function or action, or a built-in."
    defstruct [
      :name,
      :kind,
      description: "",
      params: [],
      params_schema: %{},
      returns: nil,
      signature: nil,
      impl: nil,
      builtin: false,
      lazy: false
    ]

    @type t :: %__MODULE__{}
  end

  defstruct id: nil,
            version: nil,
            root: nil,
            components: %{},
            component_order: [],
            component_groups: nil,
            functions: %{},
            function_order: [],
            actions: %{},
            action_order: [],
            calls: %{},
            defs: %{}

  @type t :: %__MODULE__{}

  @action_def_names ["ActionExpression", "OpenUrl", "ToAssistant"]

  # ── Building ─────────────────────────────────────────────────────────────

  @doc """
  Builds a library. Raises `ArgumentError` when it breaks a definition-time rule of prompt.md,
  section 3.1: reserved or duplicate names, a missing root, or names that are not uppercase.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    components = Keyword.get(opts, :components, [])
    functions = Keyword.get(opts, :functions, [])
    actions = Keyword.get(opts, :actions, [])

    lib = %__MODULE__{
      id: opts[:id],
      version: opts[:version],
      root: opts[:root],
      component_groups: opts[:component_groups],
      components: Map.new(components, &{&1.name, &1}),
      component_order: Enum.map(components, & &1.name),
      functions: Map.new(functions, &{&1.name, &1}),
      function_order: Enum.map(functions, & &1.name),
      actions: Map.new(actions, &{&1.name, &1}),
      action_order: Enum.map(actions, & &1.name),
      defs: Keyword.get(opts, :defs, %{})
    }

    lib |> validate!() |> finalize()
  end

  @doc "Defines a component. See the module docs for options."
  @spec component(String.t(), keyword()) :: Component.t()
  def component(name, opts \\ []) do
    required = opts |> Keyword.get(:required, []) |> Enum.map(&to_string/1)
    props = opts |> Keyword.get(:props, []) |> Enum.map(fn {k, v} -> {to_string(k), v} end)

    %Component{
      name: name,
      description: Keyword.get(opts, :description, ""),
      params: Enum.map(props, &param(&1, required)),
      signature: opts[:signature],
      bindable: opts |> Keyword.get(:bindable, []) |> MapSet.new(&to_string/1),
      renderer: opts[:renderer],
      form: opts[:form] && to_string(opts[:form]),
      field: opts[:field],
      value_prop: opts |> Keyword.get(:value_prop, "value") |> to_string(),
      rules_prop: opts |> Keyword.get(:rules_prop, "rules") |> to_string(),
      name_prop: opts |> Keyword.get(:name_prop, "name") |> to_string(),
      schema: object_schema(props, required, Keyword.get(opts, :description))
    }
  end

  @doc "Defines a pure custom function. `:impl` receives the arguments keyed by parameter name."
  @spec function(String.t(), keyword()) :: Call.t()
  def function(name, opts) do
    required = opts |> Keyword.get(:required, []) |> Enum.map(&to_string/1)
    params = opts |> Keyword.get(:params, []) |> Enum.map(fn {k, v} -> {to_string(k), v} end)

    %Call{
      name: name,
      kind: :function,
      description: Keyword.get(opts, :description, ""),
      params: Enum.map(params, &param(&1, required)),
      params_schema: object_schema(params, required, nil),
      returns: opts[:returns],
      signature: opts[:signature],
      impl: opts[:impl]
    }
  end

  @doc "Defines a custom action. The client does not run it; the host receives it as an event."
  @spec action(String.t(), keyword()) :: Call.t()
  def action(name, opts \\ []) do
    required = opts |> Keyword.get(:required, []) |> Enum.map(&to_string/1)
    params = opts |> Keyword.get(:params, []) |> Enum.map(fn {k, v} -> {to_string(k), v} end)

    %Call{
      name: name,
      kind: :action,
      description: Keyword.get(opts, :description, ""),
      params: Enum.map(params, &param(&1, required)),
      params_schema: object_schema(params, required, nil),
      signature: opts[:signature]
    }
  end

  @doc "A slot that takes a list of any library component: `children: Library.children()`."
  def children, do: %{"type" => "array", "items" => :components}

  @doc "A slot that takes a list of the named components."
  def children(names), do: %{"type" => "array", "items" => %{"anyOf" => Enum.map(names, &ref/1)}}

  @doc "A `$ref` to a component or action definition."
  def ref(name), do: %{"$ref" => "#/$defs/" <> name}

  @doc "An action prop: any action or `Action([...])`."
  def action_prop, do: ref("ActionExpression")

  @doc "A restricted action prop that the prompt prints as `@A | @B`."
  def action_prop(names), do: %{"anyOf" => Enum.map(names, &ref/1)}

  defp param({name, schema}, required) do
    %Param{
      name: name,
      required: name in required,
      default: schema_default(schema),
      schema: schema
    }
  end

  defp schema_default(%{"default" => d}), do: {:ok, d}
  defp schema_default(_), do: :none

  defp object_schema(props, required, description) do
    base = %{"type" => "object", "properties" => Map.new(props), "required" => required}
    if description in [nil, ""], do: base, else: Map.put(base, "description", description)
  end

  defp validate!(lib) do
    names = lib.component_order ++ lib.function_order ++ lib.action_order

    case names -- Enum.uniq(names) do
      [] -> :ok
      dups -> raise ArgumentError, "duplicate library names: #{Enum.join(Enum.uniq(dups), ", ")}"
    end

    for name <- names do
      if Builtins.reserved?(name),
        do:
          raise(
            ArgumentError,
            "#{inspect(name)} is reserved by OpenUI and cannot be used in a library"
          )

      unless Regex.match?(~r/\A[A-Z][a-zA-Z0-9_]*\z/, name),
        do:
          raise(
            ArgumentError,
            "library name #{inspect(name)} must start with an uppercase letter"
          )
    end

    if lib.root && !Map.has_key?(lib.components, lib.root),
      do: raise(ArgumentError, "root component #{inspect(lib.root)} is not in the library")

    items = Map.values(lib.components) ++ Map.values(lib.functions) ++ Map.values(lib.actions)

    for %{name: name, params: params} <- items, misplaced = required_after_optional(params) do
      raise ArgumentError,
            "#{name}: required prop #{inspect(misplaced)} comes after an optional one; " <>
              "required props must come first (a required prop with a default counts as optional)"
    end

    for %{components: members} <- lib.component_groups || [], m <- members do
      unless Map.has_key?(lib.components, m),
        do: raise(ArgumentError, "component group lists unknown component #{inspect(m)}")
    end

    lib
  end

  # Positional order (prompt.md, 3.1): the first required prop without a default that follows an
  # optional one, or nil.
  defp required_after_optional(params) do
    params
    |> Enum.reduce_while(false, fn p, seen_optional ->
      strictly_required = p.required and p.default == :none

      cond do
        strictly_required and seen_optional -> {:halt, p.name}
        strictly_required -> {:cont, false}
        true -> {:cont, true}
      end
    end)
    |> case do
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  # Expands `:components` placeholders, inlines action `$ref`s into parameter schemas and builds
  # the call registry.
  defp finalize(lib) do
    all_refs = %{"anyOf" => Enum.map(lib.component_order, &ref/1)}

    expand = fn schema -> expand_components(schema, all_refs) end

    components =
      Map.new(lib.components, fn {name, c} ->
        params = Enum.map(c.params, fn p -> %{p | schema: expand.(p.schema)} end)

        schema =
          Map.update(c.schema, "properties", %{}, &Map.new(&1, fn {k, v} -> {k, expand.(v)} end))

        {name, %{c | params: params, schema: schema}}
      end)

    lib = %{lib | components: components}
    action_defs = action_defs(lib)

    inline = fn %Param{} = p -> %{p | check: inline_action_refs(p.schema, action_defs)} end

    components =
      Map.new(lib.components, fn {name, c} ->
        {name, %{c | params: Enum.map(c.params, inline)}}
      end)

    functions =
      Map.new(lib.functions, fn {n, f} -> {n, %{f | params: Enum.map(f.params, inline)}} end)

    actions =
      Map.new(lib.actions, fn {n, a} -> {n, %{a | params: Enum.map(a.params, inline)}} end)

    lib = %{lib | components: components, functions: functions, actions: actions}
    %{lib | calls: build_calls(lib)}
  end

  defp expand_components(:components, all_refs), do: all_refs

  defp expand_components(%Jason.OrderedObject{} = obj, all_refs),
    do: map_ordered(obj, &expand_components(&1, all_refs))

  defp expand_components(map, all_refs) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, expand_components(v, all_refs)} end)

  defp expand_components(list, all_refs) when is_list(list),
    do: Enum.map(list, &expand_components(&1, all_refs))

  defp expand_components(v, _), do: v

  defp action_defs(lib) do
    builtin_defs = %{
      "ActionExpression" => action_expression_def(),
      "OpenUrl" => open_url_def(),
      "ToAssistant" => to_assistant_def()
    }

    custom_defs =
      Map.new(lib.action_order, &{&1, Map.get(lib.defs, &1, custom_action_def(lib.actions[&1]))})

    builtin_defs
    |> Map.merge(Map.take(lib.defs, @action_def_names))
    |> Map.merge(custom_defs)
    |> Map.drop(lib.component_order)
    |> Map.new(fn {name, body} -> {"#/$defs/" <> name, body} end)
  end

  defp action_expression_def do
    %{
      "anyOf" => [
        %{
          "type" => "object",
          "properties" => %{
            "type" => %{"type" => "string", "const" => "open_url"},
            "url" => %{"type" => "string"}
          },
          "required" => ["type", "url"]
        },
        %{
          "type" => "object",
          "properties" => %{
            "type" => %{"type" => "string", "const" => "continue_conversation"},
            "context" => %{"type" => "string"}
          },
          "required" => ["type"]
        },
        %{
          "type" => "object",
          "properties" => %{"type" => %{"type" => "string"}, "params" => %{"type" => "object"}},
          "required" => ["type"]
        }
      ]
    }
  end

  defp open_url_def do
    %{
      "type" => "object",
      "properties" => %{
        "type" => %{"type" => "string", "const" => "open_url"},
        "url" => %{"type" => "string"}
      },
      "required" => ["type", "url"]
    }
  end

  defp to_assistant_def do
    %{
      "type" => "object",
      "properties" => %{
        "type" => %{"type" => "string", "const" => "continue_conversation"},
        "context" => %{"type" => "string"}
      },
      "required" => ["type"]
    }
  end

  defp custom_action_def(%Call{name: name, params_schema: params}) do
    %{
      "type" => "object",
      "properties" => %{"type" => %{"type" => "string", "const" => name}, "params" => params},
      "required" => ["type", "params"]
    }
  end

  defp inline_action_refs(%{"$ref" => ref} = node, defs) when is_binary(ref) do
    case Map.fetch(defs, ref) do
      {:ok, body} -> inline_action_refs(body, Map.delete(defs, ref))
      :error -> node
    end
  end

  defp inline_action_refs(%Jason.OrderedObject{} = obj, defs),
    do: map_ordered(obj, &inline_action_refs(&1, defs))

  defp inline_action_refs(map, defs) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, inline_action_refs(v, defs)} end)

  defp inline_action_refs(list, defs) when is_list(list),
    do: Enum.map(list, &inline_action_refs(&1, defs))

  defp inline_action_refs(v, _defs), do: v

  defp build_calls(lib) do
    builtins =
      Enum.map(Builtins.functions(), fn {name, params, desc, sig} ->
        {name, builtin_call(name, :function, params, desc, sig)}
      end) ++
        Enum.map(Builtins.steps(), fn {name, params, desc, sig} ->
          {name, builtin_call(name, :action, params, desc, sig)}
        end) ++
        [{"Action", builtin_call("Action", :action, ["steps"], "", "Action(steps: any[])")}]

    Map.new(builtins)
    |> Map.merge(lib.functions)
    |> Map.merge(lib.actions)
  end

  defp builtin_call(name, kind, params, desc, sig) do
    %Call{
      name: name,
      kind: kind,
      description: desc,
      signature: sig,
      params: Enum.map(params, &%Param{name: &1}),
      builtin: true,
      lazy: Builtins.lazy?(name)
    }
  end

  # ── Queries ──────────────────────────────────────────────────────────────

  @doc "True when `name` is a component of this library."
  def component?(%__MODULE__{components: c}, name), do: Map.has_key?(c, name)

  @doc "The component named `name`, or nil."
  def get_component(%__MODULE__{components: c}, name), do: Map.get(c, name)

  @doc "The function, action or built-in named `name`, or nil."
  def get_call(%__MODULE__{calls: calls}, name), do: Map.get(calls, name)

  @doc "Component names in library order."
  def component_names(%__MODULE__{component_order: order}), do: order

  @doc "Names of the tools-free host-visible custom actions."
  def action_names(%__MODULE__{action_order: order}), do: order

  # ── LibrarySpec JSON ─────────────────────────────────────────────────────

  @doc """
  Loads a LibrarySpec JSON document (a string or already-decoded `Jason.OrderedObject` data).

  Options attach what the spec cannot carry:

    * `:functions` — `%{"Upper" => fn args -> ... end}`
    * `:renderers` — `%{"Card" => &MyComponents.card/1}`
    * `:forms` — `%{"Form" => "name"}`: components that scope form fields, and the naming prop
    * `:fields` — `%{"Input" => "input"}`: components that write form fields, and their
      `componentType`

  Bindable props are read from each signature's `$binding<type>` marker (prompt.md, 2.3).
  """
  @spec from_json(String.t() | Jason.OrderedObject.t(), keyword()) :: t()
  def from_json(json, opts \\ [])

  def from_json(json, opts) when is_binary(json),
    do: json |> Jason.decode!(objects: :ordered_objects) |> from_json(opts)

  def from_json(%Jason.OrderedObject{} = spec, opts) do
    schema = oget(spec, "schema") || %Jason.OrderedObject{values: []}
    component_specs = oget(spec, "components") || %Jason.OrderedObject{values: []}
    defs = oget(schema, "$defs") || %Jason.OrderedObject{values: []}

    component_names =
      case oget(schema, "properties") do
        %Jason.OrderedObject{values: values} -> Enum.map(values, &elem(&1, 0))
        _ -> Enum.map(component_specs.values, &elem(&1, 0))
      end

    impls = Keyword.get(opts, :functions, %{})

    platform = %{
      renderers: Keyword.get(opts, :renderers, %{}),
      forms: Keyword.get(opts, :forms, %{}),
      fields: Keyword.get(opts, :fields, %{})
    }

    components =
      for name <- component_names,
          def = oget(defs, name),
          def != nil,
          do: component_from_json(name, def, oget(component_specs, name), platform)

    functions =
      for {name, f} <- ordered_pairs(oget(schema, "functions")) do
        call_from_json(name, :function, f, oget(spec, "functions"), Map.get(impls, name))
      end

    actions =
      for {name, a} <- ordered_pairs(oget(schema, "actions")) do
        call_from_json(name, :action, a, oget(spec, "actions"), nil)
      end

    defs_plain =
      defs
      |> ordered_pairs()
      |> Map.new(fn {k, v} -> {k, plain(v)} end)
      |> Map.drop(component_names)

    lib = %__MODULE__{
      id: plain(oget(spec, "id")),
      version: plain(oget(spec, "version")),
      root: plain(oget(spec, "root")),
      component_groups: spec |> oget("componentGroups") |> plain() |> groups(),
      components: Map.new(components, &{&1.name, &1}),
      component_order: Enum.map(components, & &1.name),
      functions: Map.new(functions, &{&1.name, &1}),
      function_order: Enum.map(functions, & &1.name),
      actions: Map.new(actions, &{&1.name, &1}),
      action_order: Enum.map(actions, & &1.name),
      defs: defs_plain
    }

    finalize(lib)
  end

  defp component_from_json(name, def, cspec, platform) do
    signature = cspec && oget(cspec, "signature")
    required = def |> oget("required") |> plain() |> List.wrap()
    props = def |> oget("properties") |> ordered_pairs()

    %Component{
      name: name,
      description: (cspec && oget(cspec, "description")) || plain(oget(def, "description")) || "",
      params: Enum.map(props, fn {k, v} -> param({k, plain(v)}, required) end),
      signature: signature,
      bindable: bindable_from_signature(signature),
      renderer: Map.get(platform.renderers, name),
      form: Map.get(platform.forms, name),
      field: Map.get(platform.fields, name),
      schema: plain(def)
    }
  end

  defp call_from_json(name, kind, schema_entry, spec_entries, impl) do
    params_schema = oget(schema_entry, "params")
    required = params_schema |> oget("required") |> plain() |> List.wrap()
    props = params_schema |> oget("properties") |> ordered_pairs()
    spec_entry = spec_entries && oget(spec_entries, name)

    %Call{
      name: name,
      kind: kind,
      description: plain(oget(schema_entry, "description")) || "",
      params: Enum.map(props, fn {k, v} -> param({k, plain(v)}, required) end),
      params_schema: plain(params_schema) || %{},
      returns: plain(oget(schema_entry, "returns")),
      signature: spec_entry && plain(oget(spec_entry, "signature")),
      impl: impl
    }
  end

  defp groups(nil), do: nil

  defp groups(list) when is_list(list) do
    Enum.map(list, fn g ->
      %{name: g["name"], components: g["components"] || [], notes: g["notes"]}
    end)
  end

  defp bindable_from_signature(nil), do: MapSet.new()

  defp bindable_from_signature(sig) do
    ~r/(\w+)\??: \$binding</ |> Regex.scan(sig) |> Enum.map(&List.last/1) |> MapSet.new()
  end

  defp oget(%Jason.OrderedObject{values: values}, key) do
    case List.keyfind(values, key, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  defp oget(_, _), do: nil

  defp map_ordered(%Jason.OrderedObject{values: values}, fun),
    do: %Jason.OrderedObject{values: Enum.map(values, fn {k, v} -> {k, fun.(v)} end)}

  defp ordered_pairs(%Jason.OrderedObject{values: values}), do: values
  defp ordered_pairs(_), do: []

  # Schemas become plain maps, except `properties`, which keeps its order: the prompt prints
  # object fields in declaration order (prompt.md, section 5).
  defp plain(%Jason.OrderedObject{values: values}) do
    Map.new(values, fn
      {"properties", %Jason.OrderedObject{} = props} ->
        {"properties", map_ordered(props, &plain/1)}

      {k, v} ->
        {k, plain(v)}
    end)
  end

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(v), do: v

  @doc """
  The LibrarySpec document of this library as ordered JSON data (`Jason.OrderedObject`), ready
  for `Jason.encode!/1`. Signatures that were not given are derived from the schema.
  """
  @spec to_spec(t()) :: Jason.OrderedObject.t()
  def to_spec(%__MODULE__{} = lib) do
    alias LiveRender.OpenUI.Signature

    components_schema =
      ordered(Enum.map(lib.component_order, fn n -> {n, ref(n)} end))

    defs =
      Enum.map(lib.component_order, fn n ->
        c = lib.components[n]

        body =
          [{"type", "object"}] ++
            if(c.description != "", do: [{"description", c.description}], else: []) ++
            [{"properties", ordered(Enum.map(c.params, &{&1.name, &1.schema}))}] ++
            [{"required", for(p <- c.params, p.required, do: p.name)}]

        {n, ordered(body)}
      end) ++ extra_defs(lib)

    functions_schema =
      Enum.map(lib.function_order, fn n ->
        f = lib.functions[n]

        body =
          [{"description", f.description}, {"params", params_schema_json(f)}] ++
            if(f.returns, do: [{"returns", f.returns}], else: [])

        {n, ordered(body)}
      end)

    actions_schema =
      Enum.map(lib.action_order, fn n ->
        a = lib.actions[n]
        {n, ordered([{"description", a.description}, {"params", params_schema_json(a)}])}
      end)

    schema =
      [{"properties", components_schema}, {"$defs", ordered(defs)}] ++
        if(functions_schema != [], do: [{"functions", ordered(functions_schema)}], else: []) ++
        if(actions_schema != [], do: [{"actions", ordered(actions_schema)}], else: [])

    entries = fn order, map ->
      ordered(
        Enum.map(order, fn n ->
          item = map[n]

          {n,
           ordered([{"signature", Signature.for(lib, item)}, {"description", item.description}])}
        end)
      )
    end

    top =
      if(lib.id, do: [{"id", lib.id}], else: []) ++
        if(lib.version, do: [{"version", lib.version}], else: []) ++
        if(lib.root, do: [{"root", lib.root}], else: []) ++
        [
          {"schema", ordered(schema)},
          {"components", entries.(lib.component_order, lib.components)}
        ] ++
        if(lib.component_groups,
          do: [{"componentGroups", Enum.map(lib.component_groups, &group_json/1)}],
          else: []
        ) ++
        if(lib.function_order != [],
          do: [{"functions", entries.(lib.function_order, lib.functions)}],
          else: []
        ) ++
        if(lib.action_order != [],
          do: [{"actions", entries.(lib.action_order, lib.actions)}],
          else: []
        )

    ordered(top)
  end

  defp group_json(g) do
    ordered(
      [{"name", g.name}, {"components", g.components}] ++
        if(g[:notes], do: [{"notes", g.notes}], else: [])
    )
  end

  defp params_schema_json(%Call{params: params}) do
    ordered([
      {"type", "object"},
      {"properties", ordered(Enum.map(params, &{&1.name, &1.schema}))},
      {"required", for(p <- params, p.required, do: p.name)}
    ])
  end

  defp extra_defs(lib) do
    used = MapSet.new(["ActionExpression" | lib.action_order] ++ Map.keys(lib.defs))

    builtin =
      [{"ActionExpression", action_expression_def()}] ++
        if(MapSet.member?(used, "OpenUrl"), do: [{"OpenUrl", open_url_def()}], else: [])

    custom = Enum.map(lib.action_order, fn n -> {n, custom_action_def(lib.actions[n])} end)

    others =
      lib.defs
      |> Map.drop(["ActionExpression", "OpenUrl" | lib.action_order])
      |> Enum.sort_by(&elem(&1, 0))

    builtin ++ custom ++ others
  end

  defp ordered(pairs), do: %Jason.OrderedObject{values: pairs}
end
