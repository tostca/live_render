defmodule LiveRender.OpenUI.Components do
  @moduledoc """
  Native Phoenix renderers for `LiveRender.OpenUI.StandardLibrary`.

  Each function takes the assigns described in `LiveRender.OpenUI.Render`: `@props` (evaluated,
  string keys) and `@openui` (the node's render context). Classes follow the shadcn-style tokens
  the rest of LiveRender uses (`bg-card`, `text-muted-foreground`, ...).
  """

  use Phoenix.Component

  alias LiveRender.OpenUI.Render

  # ── Layout ───────────────────────────────────────────────────────────────

  def stack(assigns) do
    ~H"""
    <div class={["flex", direction(@props["direction"]), gap(@props["gap"])]}>
      <Render.children openui={@openui} prop="children" />
    </div>
    """
  end

  defp direction("row"), do: "flex-row flex-wrap items-start"
  defp direction(_), do: "flex-col"

  defp gap("sm"), do: "gap-2"
  defp gap("lg"), do: "gap-6"
  defp gap(_), do: "gap-4"

  def grid(assigns) do
    ~H"""
    <div class={["grid gap-4", columns(@props["columns"])]}>
      <Render.children openui={@openui} prop="children" />
    </div>
    """
  end

  defp columns(1), do: "grid-cols-1"
  defp columns(3), do: "grid-cols-1 md:grid-cols-3"
  defp columns(4), do: "grid-cols-2 md:grid-cols-4"
  defp columns(_), do: "grid-cols-1 md:grid-cols-2"

  def card(assigns) do
    ~H"""
    <section class="rounded-xl border border-border bg-card text-card-foreground shadow-sm">
      <header :if={@props["title"] || @props["description"]} class="flex flex-col gap-1.5 p-6 pb-0">
        <h3 :if={@props["title"]} class="text-lg font-semibold leading-none tracking-tight">
          {Render.text(@props["title"])}
        </h3>
        <p :if={@props["description"]} class="text-sm text-muted-foreground">
          {Render.text(@props["description"])}
        </p>
      </header>
      <div class="flex flex-col gap-3 p-6">
        <Render.children openui={@openui} prop="children" />
      </div>
    </section>
    """
  end

  def separator(assigns) do
    ~H"""
    <hr class="my-2 border-border" />
    """
  end

  # ── Text ─────────────────────────────────────────────────────────────────

  def heading(assigns) do
    ~H"""
    <.dynamic_tag tag_name={heading_tag(@props["level"])} class={heading_class(@props["level"])}>
      {Render.text(@props["text"])}
    </.dynamic_tag>
    """
  end

  defp heading_tag(level) when level in ["h1", "h2", "h3", "h4"], do: level
  defp heading_tag(_), do: "h2"

  defp heading_class("h1"), do: "text-3xl font-bold tracking-tight"
  defp heading_class("h3"), do: "text-xl font-semibold"
  defp heading_class("h4"), do: "text-lg font-semibold"
  defp heading_class(_), do: "text-2xl font-semibold tracking-tight"

  def text(assigns) do
    ~H"""
    <p class={text_class(@props["variant"])}>{Render.text(@props["text"])}</p>
    """
  end

  defp text_class("muted"), do: "text-sm text-muted-foreground"
  defp text_class("small"), do: "text-xs"
  defp text_class("heading"), do: "text-lg font-semibold"
  defp text_class(_), do: "text-sm leading-relaxed"

  def tag(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium",
      tag_color(@props["color"])
    ]}>
      {Render.text(@props["text"])}
    </span>
    """
  end

  defp tag_color("green"), do: "bg-green-100 text-green-800"
  defp tag_color("red"), do: "bg-red-100 text-red-800"
  defp tag_color("blue"), do: "bg-blue-100 text-blue-800"
  defp tag_color("yellow"), do: "bg-yellow-100 text-yellow-800"
  defp tag_color(_), do: "bg-muted text-muted-foreground"

  def callout(assigns) do
    ~H"""
    <div role="note" class={["rounded-lg border p-4", callout_class(@props["variant"])]}>
      <p :if={@props["title"]} class="mb-1 font-medium">{Render.text(@props["title"])}</p>
      <p class="text-sm">{Render.text(@props["text"])}</p>
    </div>
    """
  end

  defp callout_class("success"), do: "border-green-200 bg-green-50 text-green-900"
  defp callout_class("warning"), do: "border-yellow-200 bg-yellow-50 text-yellow-900"
  defp callout_class("error"), do: "border-red-200 bg-red-50 text-red-900"
  defp callout_class(_), do: "border-blue-200 bg-blue-50 text-blue-900"

  def link_out(assigns) do
    assigns =
      assign(assigns, :href, if(Render.safe_url?(assigns.props["url"]), do: assigns.props["url"]))

    ~H"""
    <a
      :if={@href}
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      class="text-sm font-medium text-primary underline-offset-4 hover:underline"
    >
      {Render.text(@props["label"])}
    </a>
    <span :if={!@href} class="text-sm">{Render.text(@props["label"])}</span>
    """
  end

  # ── Data ─────────────────────────────────────────────────────────────────

  def metric(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <span class="text-sm text-muted-foreground">{Render.text(@props["label"])}</span>
      <div class="flex items-baseline gap-2">
        <span class="text-2xl font-bold">{Render.text(@props["value"])}</span>
        <span :if={@props["trend"] in ["up", "down"]} class={trend_class(@props["trend"])}>
          {if @props["trend"] == "up", do: "↗", else: "↘"}
        </span>
      </div>
      <span :if={@props["detail"]} class="text-xs text-muted-foreground">
        {Render.text(@props["detail"])}
      </span>
    </div>
    """
  end

  defp trend_class("up"), do: "text-green-600"
  defp trend_class(_), do: "text-red-600"

  def progress(assigns) do
    max =
      if is_number(assigns.props["max"]) and assigns.props["max"] > 0,
        do: assigns.props["max"],
        else: 100

    value = if is_number(assigns.props["value"]), do: assigns.props["value"], else: 0

    assigns =
      assign(
        assigns,
        :pct,
        value |> Kernel./(max) |> Kernel.*(100) |> max(0) |> min(100) |> round()
      )

    ~H"""
    <div class="flex flex-col gap-1">
      <div :if={@props["label"]} class="flex justify-between text-sm">
        <span>{Render.text(@props["label"])}</span>
        <span class="text-muted-foreground">{@pct}%</span>
      </div>
      <div class="h-2 w-full overflow-hidden rounded-full bg-muted" role="progressbar" aria-valuenow={@pct}>
        <div class="h-full bg-primary" style={"width: #{@pct}%"}></div>
      </div>
    </div>
    """
  end

  # Table(columns: Col[]): each column holds its header and its cell values.
  def table(assigns) do
    columns =
      for %{type_name: "Col", props: props} <- List.wrap(assigns.props["columns"]),
          do: %{label: props["label"], data: List.wrap(props["data"])}

    rows = columns |> Enum.map(&length(&1.data)) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, columns: columns, rows: rows)

    ~H"""
    <div class="w-full overflow-x-auto">
      <table class="w-full caption-bottom text-sm">
        <thead class="border-b">
          <tr>
            <th :for={c <- @columns} class="h-10 px-2 text-left align-middle font-medium text-muted-foreground">
              {Render.text(c.label)}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={i <- row_range(@rows)} class="border-b transition-colors hover:bg-muted/50">
            <td :for={c <- @columns} class="p-2 align-middle">{cell(Enum.at(c.data, i))}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp row_range(0), do: []
  defp row_range(n), do: 0..(n - 1)

  defp cell(v) when is_list(v), do: Enum.map_join(v, ", ", &Render.text/1)
  defp cell(v), do: Render.text(v)

  # A Col renders nothing on its own; its Table reads it.
  def col(assigns) do
    ~H""
  end

  # ── Actions ──────────────────────────────────────────────────────────────

  def button(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "inline-flex h-9 items-center justify-center rounded-md px-4 py-2 text-sm font-medium transition-colors disabled:pointer-events-none disabled:opacity-50",
        button_class(@props["variant"])
      ]}
      {Render.click_attrs(@openui, "action", validate: @props["variant"] not in ["secondary", "ghost"])}
      disabled={@props["disabled"] == true or @openui.streaming}
    >
      {Render.text(@props["label"])}
    </button>
    """
  end

  defp button_class("secondary"),
    do: "bg-secondary text-secondary-foreground hover:bg-secondary/80"

  defp button_class("destructive"),
    do: "bg-destructive text-destructive-foreground hover:bg-destructive/90"

  defp button_class("ghost"), do: "hover:bg-accent hover:text-accent-foreground"
  defp button_class(_), do: "bg-primary text-primary-foreground hover:bg-primary/90"

  # ── Forms ────────────────────────────────────────────────────────────────

  def form_group(assigns) do
    ~H"""
    <div role="form" aria-label={Render.text(@props["name"])} class="flex flex-col gap-4">
      <Render.children openui={@openui} prop="children" />
    </div>
    """
  end

  def input(assigns) do
    assigns = field_assigns(assigns)

    ~H"""
    <Render.field_form openui={@openui} class="flex flex-col gap-1.5">
      <label :if={@props["label"]} for={@input_id} class="text-sm font-medium">
        {Render.text(@props["label"])}
      </label>
      <input type="hidden" name="type" value={if @props["type"] == "number", do: "number", else: "text"} />
      <input
        id={@input_id}
        name="value"
        type={input_type(@props["type"])}
        value={Render.text(@value)}
        placeholder={@props["placeholder"]}
        phx-debounce="200"
        aria-invalid={to_string(@error != nil)}
        class="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-sm"
      />
      <p :if={@error} class="text-xs text-destructive">{@error}</p>
    </Render.field_form>
    """
  end

  defp input_type(t) when t in ["email", "number", "password", "url", "date", "tel"], do: t
  defp input_type(_), do: "text"

  def textarea(assigns) do
    assigns = field_assigns(assigns)

    ~H"""
    <Render.field_form openui={@openui} class="flex flex-col gap-1.5">
      <label :if={@props["label"]} for={@input_id} class="text-sm font-medium">
        {Render.text(@props["label"])}
      </label>
      <textarea
        id={@input_id}
        name="value"
        placeholder={@props["placeholder"]}
        phx-debounce="200"
        aria-invalid={to_string(@error != nil)}
        class="min-h-20 w-full rounded-md border border-input bg-transparent px-3 py-2 text-sm shadow-sm"
      >{Render.text(@value)}</textarea>
      <p :if={@error} class="text-xs text-destructive">{@error}</p>
    </Render.field_form>
    """
  end

  def select(assigns) do
    assigns = field_assigns(assigns)

    options =
      for %{type_name: "SelectItem", props: p} <- List.wrap(assigns.props["items"]),
          do: %{value: Render.text(p["value"]), label: Render.text(p["label"])}

    assigns = assign(assigns, :options, options)

    ~H"""
    <Render.field_form openui={@openui} class="flex flex-col gap-1.5">
      <label :if={@props["label"]} for={@input_id} class="text-sm font-medium">
        {Render.text(@props["label"])}
      </label>
      <select
        id={@input_id}
        name="value"
        aria-invalid={to_string(@error != nil)}
        class="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-sm"
      >
        <option value="" disabled selected={@value in [nil, ""]}>
          {Render.text(@props["placeholder"] || "Select…")}
        </option>
        <option :for={o <- @options} value={o.value} selected={o.value == Render.text(@value)}>
          {o.label}
        </option>
      </select>
      <p :if={@error} class="text-xs text-destructive">{@error}</p>
    </Render.field_form>
    """
  end

  def select_item(assigns) do
    ~H""
  end

  def checkbox(assigns) do
    assigns = field_assigns(assigns)

    ~H"""
    <Render.field_form openui={@openui} class="flex items-center gap-2">
      <input type="hidden" name="type" value="boolean" />
      <input type="hidden" name="value" value="false" />
      <input
        id={@input_id}
        name="value"
        type="checkbox"
        value="true"
        checked={@value == true}
        class="h-4 w-4 rounded border border-input"
      />
      <label for={@input_id} class="text-sm">{Render.text(@props["label"])}</label>
      <p :if={@error} class="text-xs text-destructive">{@error}</p>
    </Render.field_form>
    """
  end

  defp field_assigns(assigns) do
    assign(assigns,
      value: Render.field_value(assigns.openui),
      error: Render.field_error(assigns.openui),
      input_id: Render.dom_id(assigns.openui, "input")
    )
  end
end
