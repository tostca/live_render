# OpenUI 1.0 in LiveRender

LiveRender implements the [OpenUI 1.0](https://github.com/thesysdev/openui/tree/main/spec) language,
LibrarySpec, prompt and message protocol in pure Elixir, and renders programs with native
Phoenix components through LiveView. There is no JavaScript runtime and no React.

- Conformance: all 59 level 1 (program) and 12 level 2 (interaction) cases of the official
  fixture suite pass, pinned at `thesysdev/openui@8d9c4c3` (`test/fixtures/openui/PINNED.md`).
  The level 2 cases also pass when replayed through real LiveView DOM events.
- Prompt: `LiveRender.OpenUI.Prompt` output is byte-identical to the reference
  `generateSystemPrompt` on 21 golden cases rendered by the upstream TypeScript.
- Components: OpenUI defines the language, not the React component library. LiveRender ships its
  own native components (`LiveRender.OpenUI.StandardLibrary`) and a bridge for existing catalogs.
  Passing the language fixtures says nothing about visual parity with OpenUI's React components.

The older `LiveRender.Format.OpenUILang` (```` ```spec ```` fences, compiled to the static
`root/elements/state` spec) still works unchanged. See [Migrating](#migrating-from-formatopenuilang).

## How it fits together

```text
model text ──▶ Parser / Parser.Stream ──▶ Runtime ──▶ Render (HEEx) ──▶ LiveView diffs
                 (pure Elixir)            │  ▲
                                          │  └─ tool_result, timer, click, input
                                          ▼
                                   effects: call_tool · schedule · event · errors · state
                                          │
                       LiveRender.OpenUI.Live executes them (start_async, messages)
```

- **Engine** (`LiveRender.OpenUI.*`, no LiveView dependency): `Source`, `Lexer`, `Statements`,
  `ExprParser`, `Parser`, `Parser.Stream`, `Materializer`, `Validation`, `Evaluator`, `Builtins`,
  `JS` (ECMA-262 coercion), `Store`, `Editing`, `Serializer`, `Protocol`, `Prompt`, `Rules`.
- **Runtime** (`LiveRender.OpenUI.Runtime`): a pure state machine for one rendered program. It
  returns effects instead of doing I/O, so tests drive it without processes.
- **LiveView adapter** (`LiveRender.OpenUI.Live`): a LiveComponent that owns a runtime, runs tools
  and refresh timers with `start_async/3`, and sends host events to the parent LiveView.
- **Tools** (`LiveRender.OpenUI.ToolHost`, `ToolAdapter`, optional `AshAdapter`): host-owned and
  allowlisted.

## Quick start

### 1. A library

```elixir
library = LiveRender.OpenUI.StandardLibrary.library()
```

or reuse an existing catalog:

```elixir
library = LiveRender.OpenUI.CatalogBridge.library(MyApp.AI.Catalog, root: "Stack")
```

### 2. Render a program

```heex
<.live_component
  module={LiveRender.OpenUI.Live}
  id={"answer-#{@message_id}"}
  library={@library}
  response={@text}
  streaming={@streaming?}
  tools={MyApp.OpenUITools}
  tool_context={%{actor: @current_user, tenant: @org_id}}
/>
```

`response` is the text received so far. Keep `streaming` true while chunks arrive: the page renders
progressively, and queries and mutations wait until it turns false.

### 3. Stream from a model

```elixir
def handle_event("ask", %{"q" => q}, socket) do
  LiveRender.OpenUI.Generate.stream("anthropic:claude-haiku-4-5", q,
    library: socket.assigns.library,
    conversation: socket.assigns.conversation,
    tools: MyApp.OpenUITools,
    tool_context: %{actor: socket.assigns.current_user},
    prompt: [inline_mode: true],
    pid: self()
  )

  conversation = LiveRender.OpenUI.Conversation.add_user(socket.assigns.conversation, q)
  {:noreply, assign(socket, conversation: conversation, text: "", streaming?: true)}
end

def handle_info({:live_render, :openui_chunk, chunk}, socket),
  do: {:noreply, update(socket, :text, &(&1 <> chunk))}

def handle_info({:live_render, :openui_done, text}, socket) do
  conversation =
    LiveRender.OpenUI.Conversation.add_assistant(socket.assigns.conversation, text,
      library: socket.assigns.library
    )

  {:noreply, assign(socket, text: text, streaming?: false, conversation: conversation)}
end
```

### 4. Handle host events

The component sends `{:openui, id, message}` to the parent LiveView:

```elixir
# A button ran @ToAssistant: continue the conversation without re-rendering by hand.
def handle_info({:openui, _id, {:event, %{"type" => "continue_conversation"} = event}}, socket) do
  conversation = LiveRender.OpenUI.Conversation.add_event(socket.assigns.conversation, event)
  # start the next Generate.stream/3 with this conversation
  {:noreply, assign(socket, conversation: conversation)}
end

def handle_info({:openui, _id, {:event, %{"type" => "open_url", "params" => %{"url" => url}}}}, socket) do
  if LiveRender.OpenUI.Render.safe_url?(url), do: {:noreply, redirect(socket, external: url)}, else: {:noreply, socket}
end

def handle_info({:openui, _id, {:errors, errors}}, socket), do: {:noreply, assign(socket, errors: errors)}
def handle_info({:openui, _id, {:state, state}}, socket), do: {:noreply, assign(socket, ui_state: state)}
def handle_info({:openui, _id, {:program, merged}}, socket), do: {:noreply, assign(socket, program: merged)}
```

Custom actions (`@CopyToClipboard("…")` from a library's `actions`) arrive as events with
`"type" => "CopyToClipboard"` and their `params`. The client never runs them.

A self-contained demo that runs without an API key: `elixir examples/openui_demo.exs`.

## Libraries

A library is a compiled LibrarySpec. Positional order is the order of `props`; required props
come first (enforced).

```elixir
import LiveRender.OpenUI.Library

Library.new(
  id: "support",
  version: "1.2.0",
  root: "Card",
  components: [
    component("Card",
      description: "A titled container",
      props: [title: %{"type" => "string"}, children: children()],
      required: [:title],
      renderer: &MyComponents.card/1
    ),
    component("Input",
      props: [name: %{"type" => "string"}, value: %{"type" => "string"}, rules: %{"type" => "object"}],
      required: [:name],
      bindable: [:value],       # prints as $binding<string>; a $var here is a two-way binding
      field: "input",           # writes {value, componentType: "input"} into form state
      renderer: &MyComponents.input/1
    ),
    component("Form",
      props: [name: %{"type" => "string"}, children: children()],
      required: [:name, :children],
      form: :name,              # gives its subtree a form name
      renderer: &MyComponents.form/1
    )
  ],
  functions: [
    function("Percent",
      params: [part: %{"type" => "number"}, total: %{"type" => "number"}],
      required: [:part, :total],
      returns: %{"type" => "string"},
      impl: fn %{"part" => p, "total" => t} -> "#{round(p / t * 100)}%" end
    )
  ],
  actions: [action("CopyToClipboard", params: [text: %{"type" => "string"}], required: [:text])]
)
```

`Library.to_spec/1` writes the LibrarySpec JSON (with derived signatures) and
`Library.from_json/2` loads one, keeping key order. `Prompt.generate/2` builds the system prompt.

### Writing a renderer

A renderer is a function component. It gets `@props` (evaluated, string keys) and `@openui` (the
node's render context):

```elixir
def card(assigns) do
  ~H"""
  <section class="card">
    <h3>{Render.text(@props["title"])}</h3>
    <Render.children openui={@openui} prop="children" />
  </section>
  """
end

def button(assigns) do
  ~H"""
  <button type="button" {Render.click_attrs(@openui, "action")}>{Render.text(@props["label"])}</button>
  """
end

def input(assigns) do
  ~H"""
  <Render.field_form openui={@openui}>
    <input name="value" value={Render.text(Render.field_value(@openui))} />
    <p :if={err = Render.field_error(@openui)}>{err}</p>
  </Render.field_form>
  """
end
```

Events carry only the node's path. The server finds the element in its own tree, so a client cannot
name an action, a tool or a state variable. A renderer that raises is contained: the node keeps its
last good render and a `render-error` is reported.

## Tools

```elixir
tools: %{"listTickets" => fn args -> {:ok, MyApp.list(args["status"])} end}   # map of functions
tools: MyApp.OpenUITools                                                       # ToolAdapter module
tools: [MyApp.OpenUITools, %{"weather" => &MyApp.weather/2}]                   # several sources
```

Only listed names run; anything else fails the query or mutation with `tool-not-found` and a hint
listing the tools. Two-arity functions and adapters get `tool_context` (actor, tenant, …), which a
program can never read or set. For Ash, see [openui-ash.md](openui-ash.md).

## Streaming, editing and persistence

- **Streaming.** Every chunk produces a valid page; the final result equals a batch parse.
  User-entered state survives later chunks.
- **Edit mode.** Pass the current program as `edit:` to `Generate.stream/3` and as `edit_base` to
  the component. While the patch streams, the current program keeps rendering; at the end the
  patch merges by statement name, unreachable statements are pruned, and the component sends
  `{:program, merged}`. User state is kept.
- **Stored messages.** `LiveRender.OpenUI.Conversation` stores turns with `]]>openui:` marker lines
  (prompt.md, section 7) and gives the model only their content. Store the `{:state, map}` messages
  and pass them back as `initial_state` when rendering a stored program again.

## Errors and repair

Errors follow language.md, section 8.3 (`LiveRender.OpenUI.Error`, JSON via `Jason`). The component
emits the list at stream end and after every change, and only when it changes; an empty list means
recovery. Send the list back to the model to repair the program. Parser errors never appear while
streaming.

## Security model

- Programs are data. Nothing is compiled or evaluated as Elixir or JavaScript.
- Tools: explicit allowlist, host context only, async, with a timeout (`tool_timeout`, default 30s)
  and a concurrency cap (`max_concurrency`, default 8).
- Limits: responses over `max_bytes` (default 512 KB) are cut and reported; expression nesting is
  capped at 200 levels; one parse inlines at most 50,000 statement references (references are
  inlined at each use, so a chain that references each statement twice would otherwise grow
  exponentially); one evaluation pass is capped at 500,000 steps; `@Each` at 10,000 elements.
  Fuzz tests feed random input through parsing, streaming, evaluation, merging and serialization.
- Output: all text goes through HEEx escaping. `Link` renders only http, https, mailto or relative
  URLs; `open_url` is an event the host decides on (`Render.safe_url?/1`).
- No atoms are created from model output (this also fixed the legacy renderer's fallback).
- Event payloads name a node path, never an action; the server looks the action up itself.

## Platform notes

Where the TypeScript reference and the normative text differ, LiveRender follows the text. These and
other platform choices are recorded in [adr/0001-openui-1.0-engine.md](adr/0001-openui-1.0-engine.md):
query refetch keys, `@Sort` collation (ICU root approximation), object equality, `runtime-error`
nulling the prop, form validation scope, and validation rule order. The full section-by-section
status is in [openui-compatibility.md](openui-compatibility.md).

## Migrating from Format.OpenUILang

| Format.OpenUILang (legacy) | OpenUI 1.0 engine |
| --- | --- |
| ```` ```spec ```` fences, snake_case catalog | any fence or none, PascalCase library |
| compiles to `root/elements/state`, `<LiveRender.render>` | evaluated tree, `<.live_component module={LiveRender.OpenUI.Live}>` |
| static values; references and expressions dropped | full expressions, `$state`, `@` functions, `@Each` |
| no actions beyond the catalog's `on` handlers | `Action`, `@Set`, `@Reset`, `@Run`, `@ToAssistant`, `@OpenUrl`, custom actions |
| no data fetching | `Query`, `Mutation`, tools |
| `Generate.stream_spec(..., format: Format.OpenUILang)` | `OpenUI.Generate.stream/3` |

Steps:

1. Build a library: `CatalogBridge.library(MyApp.AI.Catalog, root: "Stack")` keeps your components.
   Positional order changes to required props first, then `children`, then optional props, so the
   generated prompt (not your stored legacy specs) is what the model follows.
2. Replace `<LiveRender.render spec=…>` with the `LiveRender.OpenUI.Live` component and pass the raw
   text instead of a spec map.
3. Switch generation to `LiveRender.OpenUI.Generate`, and handle `{:openui, id, …}` messages.
4. For forms, inputs and bindings, add `StandardLibrary` components (`StandardLibrary.library(extra:
   CatalogBridge.components(MyApp.AI.Catalog))` combines both, if names do not collide).

Stored legacy responses keep rendering through the legacy format; they do not need converting.
