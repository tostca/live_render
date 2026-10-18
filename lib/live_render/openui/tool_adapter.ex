defmodule LiveRender.OpenUI.ToolAdapter do
  @moduledoc """
  A host-owned source of tools for `Query` and `Mutation` statements (language.md, section 6.4).

  The program names a tool; the adapter decides whether that name exists and runs it with the
  host's `context` — the current actor, tenant, or anything else the host puts there. Nothing in
  `context` comes from the program, and an adapter must never let a program choose which code
  runs beyond picking one of the names it lists.

      defmodule MyApp.TicketTools do
        @behaviour LiveRender.OpenUI.ToolAdapter

        @impl true
        def tools(_context) do
          [
            %{name: "listTickets", description: "Tickets by status",
              input_schema: %{"type" => "object", "properties" => %{"status" => %{"type" => "string"}}}}
          ]
        end

        @impl true
        def call_tool("listTickets", args, %{actor: actor}) do
          {:ok, %{"rows" => MyApp.Tickets.list(actor, args["status"])}}
        end
      end

  Return `{:error, reason}` for a failed call. Tool names are case-sensitive.
  """

  @typedoc """
  A tool descriptor. `name` is required; the rest feeds prompt generation
  (prompt.md, section 4.2, `tools`).
  """
  @type descriptor :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:input_schema) => map(),
          optional(:output_schema) => map(),
          optional(:annotations) => map()
        }

  @doc "The tools available in `context`."
  @callback tools(context :: map()) :: [descriptor() | String.t()]

  @doc "Runs tool `name`. Only called with a name `tools/1` returned for the same context."
  @callback call_tool(name :: String.t(), args :: map(), context :: map()) ::
              {:ok, term()} | {:error, term()}
end
