# Agent Handoff — Full OpenUI 1.0 Compatibility for LiveRender

**Prepared:** 2026-10-17  
**Project:** User-owned fork of [`dannote/live_render`](https://github.com/dannote/live_render)  
**Upstream specification:** [`thesysdev/openui`](https://github.com/thesysdev/openui), **OpenUI 1.0**  
**Target stack:** Elixir / Phoenix LiveView; optional Ash Framework integration

## 1. Mission

Upgrade the fork of **LiveRender** to implement the **complete OpenUI 1.0 language, library/prompt contract, message protocol, and interactive behavior**, while keeping the resulting renderer **Phoenix-native and server-driven**. The objective is not simply to recognize OpenUI syntax: it is to implement a conformant, interactive OpenUI runtime in Elixir.

**Key decisions from the discussion:**

- **Fork and extend LiveRender**; do not start a new generative-UI project.
- **No React, Vue, Svelte, or frontend-only dependency.** Render through Phoenix components / HEEx and LiveView updates. Small JavaScript hooks are acceptable when browser behavior requires them.
- Preserve the existing LiveRender component catalog, rendering architecture, and alternative wire formats where possible. Avoid breaking current applications.
- **Keep parsing and evaluation independent of LiveView** (pure Elixir); put LiveView event handling, streaming process integration, and browser rendering in an adapter/runtime layer.
- Use the official OpenUI 1.0 fixture suite for measured conformance, not visual demos alone.
- Ash integration is a useful **optional host adapter**, not a required dependency of the base LiveRender package.
- Target **full OpenUI 1.0 conformance**, with a smaller useful interactive milestone delivered earlier.

**Scope distinction:** Full OpenUI *language and protocol* compatibility is distinct from reproducing the complete React component library shipped with the OpenUI project. Native Phoenix components must be implemented or mapped separately. Do not claim visual/component parity with the React library just because the language fixtures pass.

## 2. Source of truth

Read these documents **before making implementation decisions**. Pin the referenced spec revision/commit for repeatable tests; upstream `main` may evolve.

1. [OpenUI 1.0 overview](https://github.com/thesysdev/openui/blob/main/spec/overview.md) — concepts and examples.
2. [OpenUI 1.0 language specification](https://github.com/thesysdev/openui/blob/main/spec/language.md) — normative grammar and behavior.
3. [OpenUI 1.0 prompt / LibrarySpec specification](https://github.com/thesysdev/openui/blob/main/spec/prompt.md) — library schema, prompt generation, stored messages.
4. [Official conformance fixtures](https://github.com/thesysdev/openui/tree/main/spec/fixtures/1.0) and [fixture README](https://github.com/thesysdev/openui/blob/main/spec/fixtures/1.0/README.md) — acceptance criteria.
5. [LiveRender upstream](https://github.com/dannote/live_render).

When this handoff and the normative OpenUI specification disagree, **the pinned OpenUI 1.0 specification wins**, unless maintaining a separately documented legacy LiveRender behavior under an explicitly different format.

## 3. Existing LiveRender baseline (repo inspection on 2026-10-17)

LiveRender is **not starting from zero**. It has Phoenix/HEEx components, a component catalog, multiple spec formats (JSON Patch, JSON Object, YAML, A2UI, and OpenUI Lang), streaming support, ReqLLM integration, and a basic JSON-style state resolver. The OpenUI implementation is currently a **subset translator** rather than a full interpreter.

| Existing file/module | Observed behavior / gap |
|---|---|
| `lib/live_render/format/openui_lang.ex` | OpenUI format adapter, prompt generation, fenced/raw parsing, streams and recompiles completed lines; currently teaches a restricted subset. |
| `lib/live_render/format/openui_lang/tokenizer.ex` | Handles literals, punctuation, identifiers, comments; lacks the full `$`, `@`, operator and string/stream lexical contract. |
| `lib/live_render/format/openui_lang/parser.ex` | Parses basic assignments, component calls, arrays, objects, references; lacks full expression grammar and OpenUI statement forms. |
| `lib/live_render/format/openui_lang/compiler.ex` | Converts AST to `root/elements/state` spec; `resolve_value({:ref, ...})` becomes `nil`, `extract_state/3` currently returns `%{}`, and non-component value statements are discarded. This loses information needed for reactive evaluation. |
| `lib/live_render/state_resolver.ex` | Supports LiveRender-specific JSON expressions (`$state`, `$bindState`, `$cond`, `$template`, `$concat`); **not equivalent** to OpenUI `$variable` semantics. |
| `lib/live_render.ex` | Renders nodes to Phoenix components. Uses `phx-update="ignore"` for non-streaming nodes, which needs review for ongoing reactive updates. Includes a fallback using `String.to_atom/1` on props that must be audited for untrusted input. |
| `lib/live_render/catalog.ex` + `component.ex` | Component registration and schema metadata; a good foundation for a full OpenUI LibrarySpec with ordered positional argument definitions. |
| `lib/live_render/live.ex` | Basic LiveView socket integration for streamed generated specs; needs extended state, events, interaction lifecycle, and error handling. |
| `lib/live_render/generate.ex` | ReqLLM integration and configurable formats; preserve model/provider flexibility. |
| `lib/live_render/standard_catalog.ex` and `components/*` | Existing native components (cards, tables, metrics, buttons, tabs, etc.). Not an OpenUI React component parity layer, and native form inputs need expansion. |

**Important:** These are observations from the inspected upstream files, not a complete repository-wide audit. Confirm behavior against the actual fork and its test suite first.

## 4. Proposed architecture

```text
LLM / agent (ReqLLM, Jido, AshAI, etc.)
        |
        v
OpenUI 1.0 text stream
        |
        v
Pure Elixir OpenUI engine
  - input normalization / message extraction
  - incremental tokenizer + parser / AST
  - LibrarySpec / schema validation
  - evaluation / reference resolution / functions
  - reactive state + dependency tracking
  - edits, errors and diagnostics
        |
        +-----------------------+
        |                       |
        v                       v
LiveView host/runtime       Tool runner (host-owned)
  - socket state             - explicit allowlist
  - events / forms           - Query / Mutation lifecycle
  - component projection     - optional Ash adapter
  - streaming orchestration  - authorization context
        |
        v
Native Phoenix component catalog (HEEx)
        |
        v
LiveView DOM diffs + minimal JS hooks
```

Suggested module boundaries (proposals, **not** existing APIs):

- `LiveRender.OpenUI.Tokenizer`, `.Parser`, `.AST`, `.Evaluator`, `.Validator`, `.Functions`
- `LiveRender.OpenUI.Stream`, `.State`, `.Actions`, `.Queries`, `.Editing`, `.Protocol`
- `LiveRender.OpenUI.LibrarySpec`, `.Prompt`, `.Diagnostics`
- `LiveRender.OpenUI.LiveView` (adapter), `LiveRender.OpenUI.ToolAdapter` (behavior)
- Optionally `LiveRender.OpenUI.AshAdapter` in an opt-in integration package/module

**Do not flatten the AST immediately into static props.** Preserve symbolic references, expressions, deferred actions, and variable dependencies. Evaluate a projected component tree when state/data changes, then let Phoenix LiveView patch the DOM. A projection into LiveRender's current `root/elements/state` spec is fine if it does not destroy reactive semantics and stable identity.

Server-side LiveView events are fine: OpenUI interactions must work **without sending every click back to the LLM**; they do not require implementing a full browser-side React runtime. Use LiveView's server round-trip for state updates and interactions, with lightweight JS only when appropriate.

## 5. Required capabilities / work packages

### A. Conformant grammar and forgiving parser

Implement source handling (message markers, code fences, comments, whitespace), full identifiers, `$state` identifiers, `@` functions/actions, strings, numbers/exponents, object/list literals, operator tokens and precedence, ternaries, member access and indexing, multiline statements and permissive comma rules. Support reserved `Query`, `Mutation`, and `Action` forms, including proper restrictions. Use a robust AST with source/statement identifiers for diagnostics.

Support forward references, duplicate statement names (later wins), cycles, unresolved references, root/fallback entry selection, orphan detection, and nuanced recovery. Invalid input must not crash the LiveView or discard an otherwise valid page.

### B. Evaluation and standard functions

Implement the specification's value semantics, operators, JS-like truthiness/coercion/loose equality and number-to-string behavior where required, object access, list plucking, and indexing. Add every built-in (`@Count`, `@First`, `@Last`, `@Sum`, `@Avg`, `@Min`, `@Max`, `@Filter`, `@Sort`, `@Round`, `@Abs`, `@Floor`, `@Ceil`, `@Each`). Implement proper `@Each` variable scoping, including deferred action capture and nested scopes. Implement schema-validated custom, pure synchronous functions.

**Cross-language subtlety:** OpenUI defines some operations in JavaScript terms (including coercion, rounding and locale comparison). Do not substitute Elixir defaults without fixture-based verification.

### C. Strict streaming semantics

Incrementally process chunks of **arbitrary size**, not just newline-terminated component declarations. Implicitly close unfinished strings/brackets for renderable pending statements. Keep completed statements stable; handle incoming prefixes/markers that require reconciliation. The final streamed program must match batch parsing of the same complete text. Preserve user-modified state while later chunks arrive. **Queries/mutations must not execute during generation.**

### D. Reactive state, forms and actions

Implement `$name` declarations and persisted state, default handling, reactive recomputation, two-way binding only in bindable props, form grouping, validation and submit behavior. Implement built-in `@Set`, `@Reset`, `@Run`, `@ToAssistant`, `@OpenUrl`, and custom actions; support ordered `Action([...])` sequences and standalone single actions. Correctly include context and **form state as it exists at action execution time** in host events.

Bind event handlers to actual Phoenix components, rather than merely emitting inert buttons. Add native form/input/select components (or adapt existing equivalents) and test them through LiveView.

### E. Queries, mutations and tool lifecycle

Implement `Query(tool, args, defaults, refreshSeconds?)` and `Mutation(tool, args)`: defaults, async execution, status/results, stale response protection, refresh timers, query invalidation on **directly used** `$variables`, manual `@Run`, sequential action behavior, mutation failure short-circuit, duplicate-in-flight handling and meaningful tool diagnostics. Tool execution is host-controlled and asynchronous; it must not block LiveView rendering.

Keep the core runtime tool-agnostic. Provide an optional, explicit mapping from allowed OpenUI tool names to Ash reads/actions/mutations, with the current actor and tenant authorization context. Never expose arbitrary Ash resource/action invocation to LLM-produced programs.

### F. LibrarySpec, generated prompts, editing and message protocol

Support the OpenUI 1.0 **LibrarySpec** model: root, schema, component signatures/descriptions, groups, pure functions, custom actions, ordered positional args, extensions, defaults, version/id, validation and compatibility rules. Generate the appropriate prompt for **only features actually implemented**. Preserve positional prop order when serializing schema—ordinary unordered-map transformations are not acceptable when order changes meaning.

Implement OpenUI statement-level incremental editing (replacement, append, deletion with `name = null`, unreachable-statement pruning) and merge **only after the patch stream completes**. Implement stored-message `]]>openui:content`, `context`, and `end` marker behavior, including stripping markers from rendered content and model history and persisting/restoring form context.

### G. Error recovery and security

Implement structured diagnostic codes, statement IDs, component/path information, recovery hints, smallest-possible failure isolation, safe handling of unknown functions/components/tools, render failure containment, and model feedback for repair.

Audit all paths accepting model input: remove unbounded `String.to_atom/1`; allowlist action/tool names and schemas; cap program size/depth/execution and query concurrency; constrain URLs and unsafe output; rely on HEEx escaping and safe component APIs; enforce actor/tenant authorization; never expose secret/internal tool parameters through generated output. Do not use `Code.eval_string` or dynamically execute generated Elixir/JS.

## 6. Conformance strategy — primary acceptance gate

Use [`spec/fixtures/1.0`](https://github.com/thesysdev/openui/tree/main/spec/fixtures/1.0) from a pinned upstream commit. Its main areas are:

- `grammar/`, `entry/`, `evaluation/`, `streaming/`, `errors/`, `state/`, `editing/`, `actions/`.
- **Level 1 (program):** load fixture input/chunks and LibrarySpec; produce canonical evaluated output (`root`, `errors`, `unresolved`, `orphans`, `incomplete`, plus applicable state and statements); compare with `expected.json`.
- **Level 2 (interaction):** mount a test component library, replay `interactions.json` clicks/typing/tool responses; compare emitted host events, state and tool calls.

Implement an Elixir fixture runner/adapter and continuously track **pass / fail / skipped** separately for Level 1 and Level 2. A test may only be skipped for a documented, temporary platform issue; do not silently redefine the expected result.

Add local tests for native LiveView rendering, state persistence across re-renders, stable DOM identifiers, no unintended `phx-update="ignore"` freezes, basic input/change/submit sequences, concurrent queries, security, editing, and backward compatibility across existing wire formats.

**Definition of full OpenUI 1.0 compatibility:** All applicable official 1.0 program and interaction conformance cases pass on the pinned fixture suite; remaining platform differences are explicitly documented; message/prompt contract is verified; no known security-critical bypasses. Document any aspects of the spec not covered by fixtures with additional tests.

## 7. Delivery phases and milestones

| Phase | Scope | Rough effort for one experienced Elixir developer | Exit condition |
|---|---|---:|---|
| **0. Audit and baseline** | Inspect fork, run existing tests, pin upstream spec/fixtures, build fixture runner, create compatibility map | Included in phase 1 | Reproducible baseline and documented gap list |
| **1. Language engine** | Full grammar/AST, evaluation, references, standard functions, parser errors | **2–4 weeks** | Program fixtures for grammar/entry/evaluation passing |
| **2. Interactive runtime** | State, binding, forms, validation, actions, LiveView event handling | **2–3 weeks** | State/action interaction tests and practical UI demo pass |
| **3. Data, streaming and editing** | Query/Mutation, stream correctness, edit merge, protocol | **2–3 weeks** | Data/action/stream/edit fixtures pass and real async demo works |
| **4. Hardening and interoperability** | Remaining fixture gaps, LibrarySpec/prompt fidelity, security, performance, docs | **2–3 weeks** | Full documented OpenUI 1.0 conformance and no regression in other formats |

**Planning estimates (not commitments):** A useful enhanced interactive version could take ~**3–5 weeks**; full standards-quality implementation roughly **8–13 weeks** for one experienced Elixir developer. AI agents may accelerate coding but do not replace compatibility testing, design, and review. Parallelize only work with clear module contracts.

## 8. Suggested first pull requests

1. **`test(openui): add upstream 1.0 conformance harness`** — vendor/pin fixtures and map the current failures, without rewriting production code yet.
2. **`refactor(openui): introduce lossless AST and statement evaluator`** — keep the current format interface but prevent premature reference/expression flattening.
3. **`feat(openui): implement grammar and built-ins`** — precedence, operators, `$`, `@`, references, validation, `@Each`; land in tested slices.
4. **`feat(openui): reactive LiveView state and actions`** — stable component identity, event dispatch, native inputs/forms.
5. **`feat(openui): query/mutation tool host`** — authorized tool registry and optional Ash adapter.
6. **`feat(openui): strict streaming, editing, LibrarySpec and protocol`** — full interoperability; finish remaining fixtures.

The first PR should establish an objective conformance baseline and smoke-test compatibility with every legacy spec format. This will make further agent work much safer.

## 9. Acceptance scenarios (end-to-end)

**A. Dynamic dashboard:** An LLM streams a card, metrics, chart and table; incomplete strings/statements render progressively; final stream result equals batch parse; user-selected filters update values without another LLM request.

**B. Authorized ticket workflow:** A generated form binds input variables, validates them, calls an allowlisted mutation to create a ticket through the host/Ash, displays loading/success/error state, and refreshes the ticket query. The user's actor/tenant permissions are enforced regardless of what the LLM requests.

**C. Conversational follow-up:** A generated button invokes `@ToAssistant` with context and current form values; the host stores the correct message envelope and sends the model only the intended content/context.

**D. Editing a persisted dashboard:** A user asks to change a chart from monthly to weekly. The LLM returns changed statements only; the runtime merges them after streaming, retains unrelated statements and user state, prunes orphaned nodes, and renders without a full rebuild.

**E. Failure recovery:** One invalid component, unknown function, or missing tool produces structured diagnostics but does not make the rest of the page disappear, execute unauthorized work, or crash LiveView.

## 10. Explicit non-goals / constraints

- Do **not** replace Phoenix LiveView with a React/TypeScript runtime.
- Do **not** bind LiveRender itself to Ash, SQLite, any LLM provider, or a specific application domain.
- Do **not** provide arbitrary generated code execution, raw SQL, arbitrary Phoenix module invocations, or unrestricted tool access.
- Do **not** equate official language conformance with parity for every OpenUI React visual component.
- Do **not** silently break existing `JSONPatch`, `JSONObject`, `A2UI`, `YAML`, or legacy OpenUI behavior; if incompatible, version/gate the new semantics and provide a migration guide.
- Do **not** implement features based on guesses when normative spec text/fixtures give an exact rule.

## 11. Agent's immediate next actions

1. Check out the **user's fork** (fork URL/branch to be supplied via the development workspace) and identify its upstream commit.
2. Read the three normative OpenUI 1.0 documents and the fixture README; pin their revision and note scope.
3. Run `mix test` on the fork, review `mix.exs` and current OpenUI-format tests, and collect baseline failures.
4. Create a small conformance fixture runner and coverage report before modifying core behavior.
5. Propose any architectural deviations or compatibility risks in a short ADR, then proceed with the phased implementation and tested pull requests.

**Guiding principle:** Produce a standards-conformant, maintainable **pure-Elixir OpenUI engine**, paired with a secure Phoenix LiveView renderer and optional Ash data integration. Preserve existing LiveRender functionality while making generative interfaces genuinely reactive and interactive.
