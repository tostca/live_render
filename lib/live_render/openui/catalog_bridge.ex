defmodule LiveRender.OpenUI.CatalogBridge do
  @moduledoc """
  Exposes an existing `LiveRender.Catalog` to OpenUI 1.0 programs, so current components keep
  working when an application moves to the OpenUI engine.

      library = LiveRender.OpenUI.CatalogBridge.library(MyApp.AI.Catalog, root: "Stack")

  Each catalog component becomes a library component named in PascalCase (`metric` → `Metric`).
  Its positional order is: required props in schema order, then `children` for components with an
  `:inner_block` slot, then the optional props (prompt.md, section 3.1 requires required props
  first). Renderers call the component's own `render/1` with props validated by its schema; an
  invalid optional prop is left out rather than failing the whole component.

  Catalog components have no action props. A catalog `button` gets an `action` prop here, so
  `Button("Save", @ToAssistant("Save"))` works; the click is wired around the component's markup.
  For forms, inputs and bindings use `LiveRender.OpenUI.StandardLibrary`, or combine both with the
  `:extra` option there.
  """

  use Phoenix.Component

  import LiveRender.OpenUI.Library, only: [children: 0, action_prop: 0]

  alias LiveRender.Format.OpenUILang.Compiler
  alias LiveRender.OpenUI.{Library, Render}

  @doc """
  Builds a library from a catalog module. Options: `:root`, `:id`, `:version`, `:functions`,
  `:actions`, and `:only` / `:except` (lists of catalog names such as `"metric"`).
  """
  @spec library(module(), keyword()) :: Library.t()
  def library(catalog, opts \\ []) do
    Library.new(
      id: opts[:id],
      version: opts[:version],
      root: opts[:root],
      components: components(catalog, opts),
      functions: Keyword.get(opts, :functions, []),
      actions: Keyword.get(opts, :actions, [])
    )
  end

  @doc "The catalog's components as `LiveRender.OpenUI.Library.Component` structs."
  def components(catalog, opts \\ []) do
    catalog.components()
    |> Enum.filter(fn {name, _} -> keep?(name, opts) end)
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {_name, mod} -> component(mod) end)
  end

  defp keep?(name, opts) do
    (opts[:only] == nil or name in opts[:only]) and name not in Keyword.get(opts, :except, [])
  end

  @doc "One catalog component module as a library component."
  def component(mod) do
    meta = mod.__component_meta__()
    schema = mod.json_schema()
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])
    slot? = :inner_block in meta.slots
    keys = meta.prop_order |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "children"))

    {req, opt} = Enum.split_with(keys, &(&1 in required))
    button? = meta.name == "button"

    props =
      Enum.map(req, &{&1, prop_schema(properties[&1])}) ++
        if(slot?, do: [{"children", children()}], else: []) ++
        if(button?, do: [{"action", action_prop()}], else: []) ++
        Enum.map(opt, &{&1, prop_schema(properties[&1])})

    Library.component(Compiler.to_pascal_case(meta.name),
      description: meta.description,
      props: props,
      required: req,
      renderer: fn assigns -> render(mod, slot?, button?, assigns) end
    )
  end

  # Catalog integers are numbers to OpenUI; descriptions stay for the prompt.
  defp prop_schema(nil), do: %{}
  defp prop_schema(%{"type" => "integer"} = s), do: %{s | "type" => "number"}
  defp prop_schema(s), do: s

  defp render(mod, slot?, button?, assigns) do
    props = Map.drop(assigns.props, ["children", "action"])
    validated = validate(mod, props)

    component_assigns =
      if slot? do
        Map.put(validated, :inner_block, [
          %{
            __slot__: :inner_block,
            inner_block: fn _, _ -> children_slot(assigns.openui) end
          }
        ])
      else
        validated
      end

    rendered = mod.render(Map.put(component_assigns, :__changed__, nil))
    assigns = Map.merge(assigns, %{rendered: rendered, button?: button?})

    ~H"""
    <div :if={@button?} class="contents" {Render.click_attrs(@openui, "action")}>{@rendered}</div>
    <%= if !@button? do %>{@rendered}<% end %>
    """
  end

  defp children_slot(openui) do
    assigns = %{openui: openui}

    ~H"""
    <Render.children openui={@openui} prop="children" />
    """
  end

  # Validates with the component's own schema. On failure, required props plus every optional prop
  # that still validates on its own.
  defp validate(mod, props) do
    case mod.validate_props(props) do
      {:ok, valid} ->
        valid

      {:error, _} ->
        required = mod.json_schema() |> Map.get("required", [])
        {base, optional} = Enum.split_with(props, fn {k, _} -> k in required end)
        base = Map.new(base)

        kept =
          Enum.reduce(optional, base, fn {k, v}, acc ->
            candidate = Map.put(acc, k, v)
            if match?({:ok, _}, mod.validate_props(candidate)), do: candidate, else: acc
          end)

        case mod.validate_props(kept) do
          {:ok, valid} ->
            valid

          {:error, reason} ->
            raise ArgumentError, "invalid props for #{inspect(mod)}: #{inspect(reason)}"
        end
    end
  end
end
