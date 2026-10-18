# ADR 0001: A separate OpenUI 1.0 engine next to the legacy OpenUI Lang format

- Status: accepted
- Date: 2026-10-18
- Context documents: `docs/live_render_openui_1_0_agent_handoff.md`, OpenUI 1.0 spec pinned at
  `thesysdev/openui@8d9c4c3` (see `test/fixtures/openui/PINNED.md`)

## Context

LiveRender 0.5 ships `LiveRender.Format.OpenUILang`, a translator for a subset of OpenUI Lang.
It reads ```` ```spec ```` fences, maps PascalCase calls onto the snake_case LiveRender catalog,
flattens every program into the static `root/elements/state` spec, and drops references,
expressions and value statements on the way. Existing applications depend on that output shape.

OpenUI 1.0 needs things the static spec cannot hold: expressions over `$state`, query results,
deferred actions, `@Each` templates, per-statement error reporting, and a stream that must equal
a batch parse.

## Decision

1. **Keep `LiveRender.Format.OpenUILang` as it is.** Its prompt, parser and output stay
   byte-for-byte compatible. It is documented as the legacy subset.
2. **Add a pure-Elixir engine under `LiveRender.OpenUI`.** It has no LiveView dependency:
   - `Source`, `Lexer`, `Statements`, `ExprParser`: text preparation, tokens, statement boundaries
     and the Pratt parser. One token-level boundary function serves the batch parser, the
     streaming parser and the edit merge, so the three agree byte for byte (language.md 1.4).
   - `Library`: a compiled LibrarySpec. Positional order comes from ordered lists, never from map
     key order. JSON LibrarySpecs are decoded with `Jason` ordered objects.
   - `Materializer`, `Validation`: schema-aware lowering, the drop-and-render rules and error codes.
   - `Evaluator`, `Builtins`, `JS`: evaluation with ECMA-262 coercion, loose equality and
     `Number::toString`, implemented in Elixir and checked against the fixtures.
   - `Store`, `Queries`, `Runtime`: state, the query/mutation lifecycle and action plans. The
     runtime is a pure state machine. It returns *effects* (`{:call_tool, ...}`, `{:schedule, ...}`,
     `{:event, ...}`) and the host executes them. That keeps tool calls asynchronous and lets tests
     drive the runtime without processes.
   - `Editing`, `Protocol`, `Prompt`, `Serializer`, `Rules`.
3. **The LiveView adapter is `LiveRender.OpenUI.Live`, a LiveComponent.** It owns one runtime,
   runs tools with `start_async/3`, runs refresh timers the same way, and sends host events to the
   parent LiveView as messages. Interactions are server round trips. Event payloads carry only a
   node path; the server looks the action up in its own evaluated tree, so a client cannot inject
   actions, tools or state names.
4. **Components are native Phoenix function components.** `LiveRender.OpenUI.StandardLibrary`
   provides an OpenUI-style library (layout, text, data, forms and inputs). `Library.from_catalog/2`
   exposes any existing `LiveRender.Catalog` to the OpenUI engine, so current components keep
   working under OpenUI 1.0 programs.
5. **Tools are host-owned.** `LiveRender.OpenUI.ToolAdapter` is a behaviour plus a plain-map form.
   The runtime only calls names the host listed. `LiveRender.OpenUI.AshAdapter` is optional and
   compiled only when Ash is present; it maps allowlisted tool names to explicit Ash actions and
   passes actor and tenant from the host, never from the program.

## Deviations and platform notes

- **Spec over reference where they differ.** Three places where the TypeScript reference differs
  from the normative text follow the text: references inside `Query`/`Mutation` args resolve to
  their statements (language.md 6.1) and make those statements reachable (2.3); the edit merge
  applies the multi-line ternary rule (7); and at stream end a pending redefinition replaces a
  completed statement (4, rule 7).
- **Query cache keys** use the tool name, the query statement's source and the values of the
  `$variables` written literally in its args. Arguments are evaluated when the fetch starts. That
  is the behavior 6.1 describes ("state reached through a referenced statement does not trigger a
  fetch").
- **Locale collation** (`@Sort`) is an approximation of the ICU root collation: primary weight by
  character class and base letter, then accents, then case with lowercase first. It reproduces the
  fixture order (`a, b, B, é, Z`) and common Latin text. It is not a full UCA implementation.
- **Object equality.** `==` between two arrays or objects is false (two evaluated values are never
  the same reference). Comparisons with primitives go through ToPrimitive as in IsLooselyEqual.
- **`runtime-error`** sets the failing prop to null, as language.md 8.2 says.
- **Regular expressions** in `pattern` rules run on PCRE with a length cap. The ECMAScript/ICU
  common subset listed in 5.4 behaves the same.
- **Validation rule order** is the order of section 5.4 (`required`, `email`, `url`, ...), not the
  order the program wrote, because Elixir maps do not keep key order. Pass/fail is unaffected; only
  which message shows first can differ.
- **Form validation scope.** Inside a form, a click validates the form only when its plan submits
  (a `@ToAssistant`, a custom action, a mutation run, or the default action). Renderers can skip it
  for non-submitting buttons; the standard Button does for secondary and ghost variants. The
  reference validates primary buttons only. Found by driving the demo in a browser.
- **Form state of an empty form** is `{form: {}}`. The reference falls back to the whole store,
  which would leak page state and other forms into the event (section 6.3 scopes it to the form).
- **Refresh intervals** under one second run every second.
- **Response size.** The runtime reads at most `max_bytes` (default 512 KB) of a response, renders
  that prefix like a stream that ended early, and reports a `runtime-error` explaining the cut.
- **Prompt generation** is byte-identical to the reference for the same LibrarySpec and options.
  Tool schemas keep their key order only when passed as `Jason.OrderedObject`.
- **`library.extend`** (prompt.md 2.8) is not offered as an API; Elixir libraries are built with
  `Library.new/1`, which enforces the definition-time rules of section 3.1.

## Consequences

- Two OpenUI paths exist. The legacy format keeps its tests; the new engine has the conformance
  suite plus its own tests. A migration guide (`docs/openui-1.0.md`) explains the move.
- The legacy renderer's `phx-update="ignore"` freeze stays on the legacy path only. The OpenUI
  renderer never freezes nodes, because state changes must reach the DOM after streaming ends.
- The legacy renderer's fallback no longer calls `String.to_atom/1` on prop names from model output.
