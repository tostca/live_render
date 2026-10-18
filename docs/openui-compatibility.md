# OpenUI 1.0 compatibility map

Spec revision: OpenUI 1.0 (language.md and prompt.md, 2026-10-12), fixtures pinned at
`thesysdev/openui@8d9c4c3`. "Fixtures" are the official cases under `test/fixtures/openui/1.0/`;
"tests" are LiveRender's own. Run `mix test test/live_render/openui/conformance_test.exs` for the
measured status, with `OPENUI_CONFORMANCE_REPORT=report` to write a per-case JSONL report.

## Conformance

| Level | Cases | Pass | Fail | Skipped |
| --- | ---: | ---: | ---: | ---: |
| 1. Program (`expected.json`, `validation.json`) | 59 | 59 | 0 | 0 |
| 2. Interaction (`interactions.json`), pure runtime | 12 | 12 | 0 | 0 |
| 2. Interaction, replayed through LiveView DOM events | 12 | 12 | 0 | 0 |

No case is skipped or has a redefined expectation.

## language.md

| Section | Module(s) | Coverage | Status |
| --- | --- | --- | --- |
| 1.2 Source text (markers, fences, comments) | `Protocol`, `Source` | fixtures `grammar/*-fence-*`, `*-comment-*`; tests | Done. Fences open only at the start of a line; prose quotes do not shield (spec text, stricter than the reference). |
| 1.3 Lexical elements | `Lexer` | fixtures `grammar/*-lex-*`; lexer tests | Done |
| 1.4 Statements, multi-line ternaries | `Statements` | fixtures `entry/006`, `streaming/003`; statement tests | Done. One token-level splitter for batch, stream and merge. Implements the full "open until the first complete operand after `:`" rule. |
| 1.5–1.6 Expressions, grammar | `ExprParser` | fixtures `grammar/*-expr-*`, `*-member-digits-*`; tests | Done. Nesting deeper than 200 levels is cut. |
| 2.1 Statement kinds | `Parser` | fixtures `evaluation/001`, `012`, `errors/010` | Done |
| 2.2 Entry | `Parser` | fixtures `entry/` | Done |
| 2.3 References, hoisting, orphans | `Materializer`, `Parser` | fixtures `evaluation/003`, `errors/003`, `errors/012` | Done. References in Query/Mutation args resolve and count as reachable (spec text). |
| 2.4 Duplicate names | `Parser` | fixture `evaluation/004`; streaming tests | Done |
| 3.1–3.3 Values, operators, member access | `JS`, `Evaluator` | fixtures `evaluation/005`, `006`; JS tests | Done. ECMA-262 ToNumber, IsLooselyEqual and Number::toString implemented in Elixir. |
| 3.4 Built-ins | `Builtins`, `Collation` | fixture `evaluation/008`; evaluation tests | Done. `localeCompare` approximates ICU root collation (see ADR). |
| 3.5 `@Each` | `Evaluator`, `Materializer` | no fixture; evaluation and runtime tests | Done, including shadowing by nested `@Each` and action capture. |
| 3.6 Custom functions | `Evaluator`, `Materializer` | fixtures `evaluation/010`, `011`, `errors/014` | Done |
| 4 Streaming | `Parser.Stream`, `Runtime` | fixtures `streaming/`; every-split-point equivalence tests | Done |
| 5.1 State store | `Store`, `Runtime` | fixture `state/001`; runtime tests | Done |
| 5.2 Two-way binding | `Evaluator`, `Runtime`, `Render` | fixture `state/002` (L1, L2, DOM) | Done |
| 5.3 Form state | `Runtime`, `Tree` | fixtures `state/003`, `004` (L2, DOM) | Done |
| 5.4 Validation rules | `Rules`, `Runtime` | fixture `state/005`; rules and LiveView tests | Done. Rules run in a fixed order; a form validates only for actions that submit it (see ADR). |
| 6.1 Query lifecycle | `Runtime` | fixture `actions/006`; runtime query tests | Done. Refetch on literal `$var` changes only; stale results discarded; refresh timers. |
| 6.2 Mutation lifecycle | `Runtime` | fixtures `actions/007`, `008` | Done |
| 6.3 Actions and events | `Evaluator`, `Runtime` | fixtures `actions/001`–`011` | Done |
| 6.4 Tool resolution | `ToolHost`, `Runtime` | fixture `actions/008`; tool host tests | Done (map, `ToolAdapter` module, list; MCP clients via an adapter module). |
| 7 Incremental editing | `Editing`, `Live` | fixtures `editing/`; editing and scenario tests | Done. Merge applies the ternary rule (spec text); merge happens after the patch stream ends. |
| 8.1–8.2 Recovery, error codes | `Materializer`, `Validation`, `Runtime`, `Render` | fixtures `errors/` | Done, including `render-error` containment. |
| 8.3 Error object, emission rules | `Error`, `Runtime`, `Live` | fixture `errors/005`; runtime and LiveView tests | Done |
| 8.4 Component validation | `Validation` | fixtures `errors/*-validate-*` | Done |
| 9.2 Serialization | `Serializer` | fixture `grammar/010`; serializer tests | Done |

## prompt.md

| Section | Module(s) | Coverage | Status |
| --- | --- | --- | --- |
| 2 LibrarySpec (`id`, `version`, `root`, schema, signatures, functions, actions, groups) | `Library`, `Signature` | library tests, round trips | Done. Ordered decoding keeps positional order. |
| 2.8 `extend` | — | — | Not provided as an API; build a new library with `Library.new/1` (or `StandardLibrary.library(extra: …)`). |
| 3.1 Definition-time rules | `Library.new/1` | library tests | Done (reserved and duplicate names, uppercase, root, groups, required-before-optional). |
| 4–5 Prompt generation, signatures | `Prompt`, `Signature` | 21 golden prompts rendered by the reference | Done, byte-identical. Tool schemas keep key order when passed as `Jason.OrderedObject`. |
| 6 Conversation, events, edit mode | `Conversation`, `Generate` | conversation and generate tests | Done |
| 7 Message protocol | `Protocol` | protocol tests | Done |

## Beyond the spec

| Item | Where |
| --- | --- |
| Native Phoenix component library | `StandardLibrary`, `Components` |
| Existing LiveRender catalogs under OpenUI | `CatalogBridge` |
| Optional Ash tool adapter (actor/tenant, policies) | `AshAdapter`, [openui-ash.md](openui-ash.md) |
| Runnable demo | `examples/openui_demo.exs` |
| Response size cap | `Runtime` `:max_bytes` |

## Known differences from the React reference

These are platform choices, not spec violations; each is in the ADR.

- Validation rules are checked in the order of section 5.4, not the order written (Elixir maps do
  not keep key order).
- `formState` inside a form with no fields yet is `{form: {}}`; the reference falls back to the
  whole store.
- A refresh interval shorter than one second runs every second.
- `@Sort`'s string order is an ICU-root approximation, exact for Latin text and the fixtures.
- OpenUI's React component library (charts, tabs, etc.) is not reproduced; the standard library is
  a smaller native set, and any Phoenix component can be added.
