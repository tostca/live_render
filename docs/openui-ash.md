# OpenUI tools backed by Ash

`LiveRender.OpenUI.AshAdapter` lets an OpenUI program read and change data through Ash actions
that you pick by name. The program gets a list of tool names and nothing else: it cannot name a
resource, an action, a filter or an actor.

The adapter is optional. It is compiled only when your application depends on Ash 3.

## Setup

Add Ash to your dependencies (policies also need a SAT solver, `:picosat_elixir` or
`:simple_sat`):

```elixir
{:ash, "~> 3.0"},
{:picosat_elixir, "~> 0.2"}
```

Declare the tools in a module:

```elixir
defmodule MyApp.OpenUITools do
  use LiveRender.OpenUI.AshAdapter

  alias MyApp.Support.Ticket

  tool "listTickets", Ticket, :list,
    description: "Tickets, filtered by status",
    load: [:comment_count],
    limit: 50

  tool "createTicket", Ticket, :create
  tool "closeTicket", Ticket, :close        # update: needs "id"
  tool "deleteTicket", Ticket, :destroy     # destroy: needs "id"
  tool "openTicketCount", Ticket, :open_count  # generic action
end
```

`tool/4` is a macro, so `mix format` adds parentheses unless your `.formatter.exs` lists
`tool: 3, tool: 4` under `locals_without_parens`.

A program can now use those names:

```
$status = "open"
$title = ""
tickets = Query("listTickets", {status: $status}, {rows: []})
create = Mutation("createTicket", {title: $title})
root = Stack([
  Input("title", "Title", $title),
  Button("Create", Action([@Run(create), @Run(tickets)])),
  Table([Col("Title", tickets.rows.title), Col("Comments", tickets.rows.comment_count)])
])
```

(Component signatures depend on your library; these follow the conformance test library.)

### Options

| Option | Applies to | Meaning |
|---|---|---|
| `:description` | all | Shown to the model. Defaults to the action's description. |
| `:load` | all but destroy | Public, non-sensitive calculations, aggregates and relationships to load and return. |
| `:fields` | all | The attributes (and `:load` names) to return. Default: every public, non-sensitive attribute plus `:load`. |
| `:read_action` | update, destroy | The read action that finds the record. Default: the primary read action. |
| `:limit` | read | Maximum rows returned. Default 100. |
| `:pagination` | read | `true` lets the program pass `limit` (capped by `:limit`) and `offset`. |
| `:result` | read | `:rows` (default) or `:list`. |

Declarations are checked when the module compiles. An unknown action, an action marked
`public?: false`, a private or sensitive field in `:fields`, or a private calculation in `:load`
is a compile error.

### Inputs

A tool accepts the action's public arguments and the public attributes in its `accept` list.
Update and destroy tools also take the primary key (`"id"`, or every key of a composite key).
Every other key is dropped, the way OpenUI drops excess component arguments. The multitenancy
attribute is never taken from the program.

`tools/1` returns a JSON Schema per tool, built from the same inputs: Ash types map to JSON types,
`one_of` and `Ash.Type.Enum` become `enum`, length and range constraints carry over, and inputs the
action requires are listed under `required`. Pass the descriptors to your prompt builder
(`LiveRender.OpenUI.ToolHost.descriptors(MyApp.OpenUITools, context)`).

### Results

| Action | Result |
|---|---|
| read | `%{"rows" => [...]}`; with `pagination: true` also `"limit"`, `"offset"`, `"hasMore"`; `result: :list` returns the bare list |
| read with `get? true` | one record map, or `nil` |
| create, update | the record |
| destroy | the destroyed record |
| generic action | the return value (records inside are converted too); `nil` without a return type |

Records become string-keyed maps of public, non-sensitive attributes, plus whatever `:load`
names. Related records follow the same rule. A value hidden by a field policy becomes `nil`.

### Errors

`call_tool/3` never raises. It returns:

- `{:error, "forbidden"}` when a policy denies the call
- `{:error, "not found"}` when the record does not exist, belongs to another tenant, or is
  filtered out by a read policy
- `{:error, "invalid input: title: is required; priority: must be less than or equal to 5"}` for
  validation errors
- `{:error, "internal error"}` for anything else; the details are logged on the server

The runtime turns these into `tool-error` diagnostics on the `Query` or `Mutation` statement.

## Security model

- **Allowlist.** Only names declared with `tool/4` exist. Each maps to one resource and one action,
  fixed at compile time. An unknown name gives `tool-not-found` from `LiveRender.OpenUI.ToolHost`.
- **Actor and tenant come from the host.** Every Ash call uses `actor: context[:actor]`,
  `tenant: context[:tenant]` and `authorize?: true`. The context is what your LiveView passes; the
  program never sees or sets it. There is no option to skip authorization.
- **Policies apply.** Update and destroy load the record through a read action with the same
  actor and tenant, so read policies and tenant isolation run before the change. Each call also
  sets the Ash context `%{openui: %{tool: name}}`, which a policy can check if OpenUI calls need
  stricter rules than the rest of your app.
- **No query building from the program.** Filters, sorts and loads are not inputs. Paging is
  available only when the tool declares it.
- **No data leaks in results or errors.** Private and sensitive attributes are never returned.
  Error messages leave out policy breakdowns, stack traces and module names.

## LiveView wiring

`LiveRender.OpenUI.Live` is the LiveComponent that hosts an OpenUI program. Give it the tools
module and the authorization context for the current user (attributes other than `tools` and
`tool_context` are shown for illustration; see the component's docs):

```heex
<.live_component
  module={LiveRender.OpenUI.Live}
  id="assistant-ui"
  response={@response}
  tools={MyApp.OpenUITools}
  tool_context={%{actor: @current_user, tenant: @current_org.id}}
/>
```

The component runs tool calls asynchronously and passes `tool_context` to the adapter unchanged.
Build `tool_context` from the session (for example in `on_mount`), never from model output or
client params.

`tools` also accepts a list, so you can combine Ash tools with plain functions:

```heex
tools={[MyApp.OpenUITools, %{"now" => fn _ -> DateTime.utc_now() end}]}
```

## Caveats

- Every declared tool is listed for every user. Policies still decide what a call may do, but a
  tool the user can never run still appears in the prompt.
- With Ash 3.27's ETS data layer, a policy that denies an *atomic* update raises inside Ash
  instead of returning `Ash.Error.Forbidden`. The adapter reports that as `"internal error"`.
  If you use ETS (in tests, say), set `require_atomic? false` on update and destroy actions.
