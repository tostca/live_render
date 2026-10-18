defmodule LiveRender.OpenUI.StandardLibrary do
  @moduledoc """
  A ready-made OpenUI library with native Phoenix components: layout, text, data display,
  buttons, forms and inputs.

      library = LiveRender.OpenUI.StandardLibrary.library()
      prompt = LiveRender.OpenUI.Prompt.generate(library, tools: tool_names)

  Positional order is the order below; required props come first (prompt.md, section 3.1).

  | Component | Signature |
  | --- | --- |
  | Stack | `Stack(children, direction?: "row" \\| "column", gap?: "sm" \\| "md" \\| "lg")` |
  | Grid | `Grid(children, columns?: number)` |
  | Card | `Card(title, children?, description?)` |
  | Separator | `Separator()` |
  | Heading | `Heading(text, level?: "h1" \\| "h2" \\| "h3" \\| "h4")` |
  | Text | `Text(text, variant?: "body" \\| "muted" \\| "small" \\| "heading")` |
  | Tag | `Tag(text, color?: "gray" \\| "green" \\| "red" \\| "blue" \\| "yellow")` |
  | Callout | `Callout(text, title?, variant?: "info" \\| "success" \\| "warning" \\| "error")` |
  | Link | `Link(label, url)` |
  | Metric | `Metric(label, value, detail?, trend?: "up" \\| "down" \\| "neutral")` |
  | Progress | `Progress(value, label?, max?)` |
  | Table | `Table(columns: Col[])` |
  | Col | `Col(label, data?)` |
  | Button | `Button(label, action?, variant?, disabled?)` |
  | Form | `Form(name, children)` |
  | Input | `Input(name, label?, placeholder?, value?: $binding<string>, type?, rules?)` |
  | TextArea | `TextArea(name, label?, placeholder?, value?: $binding<string>, rules?)` |
  | Select | `Select(name, items: SelectItem[], label?, value?: $binding<string>, placeholder?, rules?)` |
  | SelectItem | `SelectItem(value, label)` |
  | Checkbox | `Checkbox(name, label, value?: $binding<boolean>)` |

  Pass `:extra` to add your own components (built with `LiveRender.OpenUI.Library.component/2`),
  and `:functions`, `:actions`, `:id`, `:version` as for `LiveRender.OpenUI.Library.new/1`.
  """

  import LiveRender.OpenUI.Library, only: [component: 2, children: 0, children: 1, action_prop: 0]

  alias LiveRender.OpenUI.{Components, Library}

  @string %{"type" => "string"}
  @number %{"type" => "number"}
  @boolean %{"type" => "boolean"}
  @rules %{"type" => "object"}

  @doc "The standard library. See the module docs for options."
  @spec library(keyword()) :: Library.t()
  def library(opts \\ []) do
    Library.new(
      id: Keyword.get(opts, :id, "live_render"),
      version: Keyword.get_lazy(opts, :version, &library_version/0),
      root: Keyword.get(opts, :root, "Stack"),
      components: components() ++ Keyword.get(opts, :extra, []),
      functions: Keyword.get(opts, :functions, []),
      actions: Keyword.get(opts, :actions, []),
      component_groups: Keyword.get(opts, :component_groups, groups(opts))
    )
  end

  # Mix is not available in a release, so the version comes from the loaded application.
  defp library_version do
    case Application.spec(:live_render, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp groups(opts) do
    extra = opts |> Keyword.get(:extra, []) |> Enum.map(& &1.name)

    [
      %{name: "Layout", components: ~w(Stack Grid Card Separator)},
      %{name: "Content", components: ~w(Heading Text Tag Callout Link)},
      %{name: "Data", components: ~w(Metric Progress Table Col)},
      %{name: "Actions", components: ~w(Button)},
      %{
        name: "Forms",
        components: ~w(Form Input TextArea Select SelectItem Checkbox),
        notes: ["Put inputs inside a Form to send their values with the form's actions."]
      }
    ] ++ if(extra == [], do: [], else: [%{name: "Custom", components: extra}])
  end

  @doc "The standard components, in library order."
  def components do
    [
      component("Stack",
        description: "Lays out children in a column (default) or a row",
        props: [children: children(), direction: enum(~w(row column)), gap: enum(~w(sm md lg))],
        required: [:children],
        renderer: &Components.stack/1
      ),
      component("Grid",
        description: "A responsive grid; columns is 1 to 4",
        props: [children: children(), columns: @number],
        required: [:children],
        renderer: &Components.grid/1
      ),
      component("Card",
        description: "A titled container",
        props: [title: @string, children: children(), description: @string],
        required: [:title],
        renderer: &Components.card/1
      ),
      component("Separator",
        description: "A horizontal rule between sections",
        renderer: &Components.separator/1
      ),
      component("Heading",
        description: "A section heading; h1 for the page title only",
        props: [text: @string, level: enum(~w(h1 h2 h3 h4))],
        required: [:text],
        renderer: &Components.heading/1
      ),
      component("Text",
        description: "A paragraph of text",
        props: [text: @string, variant: enum(~w(body muted small heading))],
        required: [:text],
        renderer: &Components.text/1
      ),
      component("Tag",
        description: "A small colored label for a status or category",
        props: [text: @string, color: enum(~w(gray green red blue yellow))],
        required: [:text],
        renderer: &Components.tag/1
      ),
      component("Callout",
        description: "A highlighted note",
        props: [text: @string, title: @string, variant: enum(~w(info success warning error))],
        required: [:text],
        renderer: &Components.callout/1
      ),
      component("Link",
        description: "A link that opens in a new tab; http, https or mailto URLs only",
        props: [label: @string, url: @string],
        required: [:label, :url],
        renderer: &Components.link_out/1
      ),
      component("Metric",
        description: "A labeled number or short value, with an optional trend",
        props: [
          label: @string,
          value: %{"anyOf" => [@number, @string]},
          detail: @string,
          trend: enum(~w(up down neutral))
        ],
        required: [:label, :value],
        renderer: &Components.metric/1
      ),
      component("Progress",
        description: "A progress bar; value out of max (default 100)",
        props: [value: @number, label: @string, max: @number],
        required: [:value],
        renderer: &Components.progress/1
      ),
      component("Table",
        description: "A table built from columns",
        props: [columns: children(["Col"])],
        required: [:columns],
        renderer: &Components.table/1
      ),
      component("Col",
        description: "One table column: a header and its cell values, top to bottom",
        props: [label: @string, data: %{"type" => "array"}],
        required: [:label],
        renderer: &Components.col/1
      ),
      component("Button",
        description: "A clickable button; with no action it sends its label to the assistant",
        props: [
          label: @string,
          action: action_prop(),
          variant: enum(~w(primary secondary destructive ghost)),
          disabled: @boolean
        ],
        required: [:label],
        renderer: &Components.button/1
      ),
      component("Form",
        description: "Groups its inputs under a form name; their values travel with its actions",
        props: [name: @string, children: children()],
        required: [:name, :children],
        form: :name,
        renderer: &Components.form_group/1
      ),
      component("Input",
        description: "A one-line text field",
        props: [
          name: @string,
          label: @string,
          placeholder: @string,
          value: @string,
          type: enum(~w(text email number password url date tel)),
          rules: @rules
        ],
        required: [:name],
        bindable: [:value],
        field: "input",
        renderer: &Components.input/1
      ),
      component("TextArea",
        description: "A multi-line text field",
        props: [
          name: @string,
          label: @string,
          placeholder: @string,
          value: @string,
          rules: @rules
        ],
        required: [:name],
        bindable: [:value],
        field: "textarea",
        renderer: &Components.textarea/1
      ),
      component("Select",
        description: "A dropdown",
        props: [
          name: @string,
          items: children(["SelectItem"]),
          label: @string,
          value: @string,
          placeholder: @string,
          rules: @rules
        ],
        required: [:name, :items],
        bindable: [:value],
        field: "select",
        renderer: &Components.select/1
      ),
      component("SelectItem",
        description: "One option of a Select",
        props: [value: @string, label: @string],
        required: [:value, :label],
        renderer: &Components.select_item/1
      ),
      component("Checkbox",
        description: "A checkbox with a label",
        props: [name: @string, label: @string, value: @boolean],
        required: [:name, :label],
        bindable: [:value],
        field: "checkbox",
        renderer: &Components.checkbox/1
      )
    ]
  end

  defp enum(values), do: %{"type" => "string", "enum" => values}
end
