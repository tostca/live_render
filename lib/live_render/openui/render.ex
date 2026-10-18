defmodule LiveRender.OpenUI.Render do
  @moduledoc """
  Renders an evaluated OpenUI tree with native Phoenix function components.

  Each library component has a renderer: a function component that receives

    * `@props` — the evaluated props, keyed by prop name (strings)
    * `@openui` — the render context (`LiveRender.OpenUI.Render.Ctx`) for this node

  and uses the helpers here to render child props and wire interactions:

      def card(assigns) do
        ~H\"\"\"
        <div class="card">
          <h3>{@props["title"]}</h3>
          <Render.children openui={@openui} prop="children" />
        </div>
        \"\"\"
      end

      def button(assigns) do
        ~H\"\"\"
        <button type="button" {Render.click_attrs(@openui, "action")}>{@props["label"]}</button>
        \"\"\"
      end

  Interactions carry only the node's path in the tree (`phx-value-node`). The server finds the
  element again in its own evaluated tree, so a client cannot name actions, tools or state.

  A renderer that raises is contained: the node renders its last good version (or nothing) and a
  `render-error` is reported (language.md, section 8.2).
  """

  use Phoenix.Component

  alias LiveRender.OpenUI.{Element, Error, JS, Library, Runtime, Tree}

  defmodule Ctx do
    @moduledoc """
    The render context of one node.

      * `path` — the node's path from the root (see `LiveRender.OpenUI.Tree`)
      * `form` — the nearest enclosing form name, or nil
      * `element` — the node's `%Element{}`
      * `target` — the LiveComponent's `@myself`, for `phx-target`
      * `dom_id` — the id prefix of the rendered program
    """
    defstruct lib: nil,
              runtime: nil,
              target: nil,
              dom_id: "openui",
              path: [],
              form: nil,
              element: nil,
              streaming: false,
              broken: MapSet.new(),
              last_good: %{},
              check: false

    @type t :: %__MODULE__{}
  end

  # ── Rendering values ─────────────────────────────────────────────────────

  @doc "Renders the root of a tree."
  attr(:tree, :any, required: true)
  attr(:openui, Ctx, required: true)

  def tree(assigns) do
    ~H"""
    {render_value(@tree, @openui, [])}
    """
  end

  @doc """
  Renders the value of one of the current node's props in a component position: components
  render, strings, numbers and booleans render as text, and null renders nothing.
  """
  attr(:openui, Ctx, required: true)
  attr(:prop, :string, required: true, doc: "the prop of the current node to render")
  attr(:value, :any, doc: "defaults to the prop's value")

  def children(assigns) do
    value =
      Map.get_lazy(assigns, :value, fn -> Map.get(assigns.openui.element.props, assigns.prop) end)

    assigns =
      assign(
        assigns,
        :rendered,
        render_value(value, assigns.openui, assigns.openui.path ++ [assigns.prop])
      )

    ~H"""
    {@rendered}
    """
  end

  @doc false
  def render_value(_value, %Ctx{check: true, element: %Element{}}, _path), do: ""
  def render_value(nil, _ctx, _path), do: ""
  def render_value(v, _ctx, _path) when is_binary(v), do: v
  def render_value(v, _ctx, _path) when is_boolean(v), do: to_string(v)

  def render_value(v, _ctx, _path) when is_number(v) or v in [:infinity, :neg_infinity, :nan],
    do: JS.number_to_string(v)

  def render_value(list, ctx, path) when is_list(list) do
    assigns = %{
      items:
        list |> Enum.with_index() |> Enum.map(fn {v, i} -> render_value(v, ctx, path ++ [i]) end)
    }

    ~H"""
    <%= for item <- @items do %>{item}<% end %>
    """
  end

  def render_value(%Element{} = el, ctx, path), do: render_element(el, ctx, path)
  def render_value(_other, _ctx, _path), do: ""

  # A broken node shows its last good version, or nothing.
  defp render_element(el, ctx, path) do
    if MapSet.member?(ctx.broken, path) do
      case Map.fetch(ctx.last_good, path) do
        {:ok, good} -> call_renderer(good, ctx, path)
        :error -> ""
      end
    else
      call_renderer(el, ctx, path)
    end
  end

  defp call_renderer(el, ctx, path) do
    node_ctx = %{ctx | path: path, element: el, form: Tree.form_of(el, ctx.lib, ctx.form)}
    assigns = %{__changed__: nil, props: el.props, openui: node_ctx}

    case renderer(ctx.lib, el.type_name) do
      fun when is_function(fun, 1) -> fun.(assigns)
      module when is_atom(module) and not is_nil(module) -> module.render(assigns)
      nil -> fallback(assigns)
    end
  end

  defp renderer(lib, type) do
    case Library.get_component(lib, type) do
      %{renderer: r} -> r
      nil -> nil
    end
  end

  # A component without a renderer shows its children, so content is never lost.
  defp fallback(assigns) do
    assigns =
      assign(assigns, :kids, for({k, v} <- assigns.props, element_like?(v), do: k) |> Enum.sort())

    ~H"""
    <div data-openui-component={@openui.element.type_name}>
      <.children :for={k <- @kids} openui={@openui} prop={k} />
    </div>
    """
  end

  defp element_like?(%Element{}), do: true
  defp element_like?(list) when is_list(list), do: Enum.any?(list, &element_like?/1)
  defp element_like?(_), do: false

  # ── Render-error containment ─────────────────────────────────────────────

  @doc """
  Renders every node once, alone (children left out), and returns the paths whose renderer
  raised with a `render-error` for each. Run it outside the render phase; pass the result to the
  context's `broken` set.
  """
  @spec check(Element.t() | nil, Ctx.t()) :: {MapSet.t(), [Error.t()]}
  def check(nil, _ctx), do: {MapSet.new(), []}

  def check(%Element{} = tree, %Ctx{} = ctx) do
    tree
    |> Tree.elements(ctx.lib)
    |> Enum.reduce({MapSet.new(), []}, fn {el, path, form}, {broken, errors} ->
      probe_ctx = %{ctx | check: true, form: form, broken: MapSet.new(), last_good: %{}}

      try do
        el |> call_renderer(%{probe_ctx | form: form}, path) |> Phoenix.HTML.Safe.to_iodata()
        {broken, errors}
      rescue
        e ->
          error = %Error{
            source: :runtime,
            code: "render-error",
            component: el.type_name,
            statement_id: el.statement_id,
            message: "Rendering #{el.type_name} failed: #{Exception.message(e)}"
          }

          {MapSet.put(broken, path), [error | errors]}
      end
    end)
    |> then(fn {broken, errors} -> {broken, Enum.reverse(errors)} end)
  end

  # ── Helpers for renderers ────────────────────────────────────────────────

  @doc """
  Attributes that make an element run the action in prop `prop` when clicked:

      <button type="button" {Render.click_attrs(@openui, "action")}>...</button>
  """
  @spec click_attrs(Ctx.t(), String.t()) :: list()
  def click_attrs(%Ctx{} = ctx, prop \\ "action") do
    [
      {"phx-click", "openui:click"},
      {"phx-value-node", Tree.encode_path(ctx.path)},
      {"phx-value-prop", prop},
      {"phx-target", ctx.target}
    ]
  end

  @doc """
  Wraps a field's input in a small form that reports changes for this node. The input's `name`
  must be `"value"`.

      <Render.field_form openui={@openui}>
        <input name="value" value={Render.field_value(@openui)} />
      </Render.field_form>
  """
  attr(:openui, Ctx, required: true)
  attr(:class, :any, default: nil)
  slot(:inner_block, required: true)

  def field_form(assigns) do
    ~H"""
    <form
      id={dom_id(@openui, "form")}
      class={@class}
      phx-change="openui:input"
      phx-submit="openui:submit"
      phx-target={@openui.target}
      autocomplete="off"
    >
      <input type="hidden" name="node" value={Tree.encode_path(@openui.path)} />
      {render_slot(@inner_block)}
    </form>
    """
  end

  @doc "The value a field shows: its bound `$variable`, its form field, or its static value."
  def field_value(%Ctx{runtime: nil, element: el}), do: Map.get(el.props, "value")

  def field_value(%Ctx{runtime: rt, element: el, form: form}),
    do: Runtime.field_value(rt, el, form)

  @doc "The field's validation error, or nil."
  def field_error(%Ctx{runtime: nil}), do: nil

  def field_error(%Ctx{runtime: rt, element: el, form: form}) do
    case Map.get(el.props, "name") do
      name when is_binary(name) -> Runtime.field_error(rt, form, name)
      _ -> nil
    end
  end

  @doc "A DOM id for this node, stable across re-renders while the tree keeps its shape."
  def dom_id(%Ctx{dom_id: prefix, path: path}, suffix \\ nil) do
    base = prefix <> "-n" <> Enum.map_join(path, "", &("-" <> safe_segment(&1)))
    if suffix, do: base <> "-" <> suffix, else: base
  end

  defp safe_segment(i) when is_integer(i), do: Integer.to_string(i)
  defp safe_segment(s), do: String.replace(s, ~r/[^a-zA-Z0-9_]/, "_")

  @doc "Display text for a prop value: numbers through `Number::toString`, null as empty."
  def text(nil), do: ""
  def text(v) when is_binary(v), do: v

  def text(v) when is_number(v) or v in [:infinity, :neg_infinity, :nan],
    do: JS.number_to_string(v)

  def text(v) when is_boolean(v), do: to_string(v)
  def text(_), do: ""

  @doc "True when a URL is safe to put in an `href`: http, https or mailto, or a relative path."
  def safe_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: nil, host: nil, path: "/" <> _} -> true
      %URI{scheme: scheme} when scheme in ["http", "https", "mailto"] -> true
      _ -> false
    end
  end

  def safe_url?(_), do: false
end
