if Code.ensure_loaded?(Ash) do
  defmodule LiveRender.OpenUI.AshAdapter do
    @moduledoc """
    Exposes an explicit, allowlisted set of Ash actions as OpenUI tools.

    Only compiled when `:ash` is a dependency of the host application.

        defmodule MyApp.OpenUITools do
          use LiveRender.OpenUI.AshAdapter

          tool "listTickets", MyApp.Support.Ticket, :list,
            description: "Tickets, filtered by status",
            limit: 50,
            pagination: true

          tool "createTicket", MyApp.Support.Ticket, :create
          tool "closeTicket", MyApp.Support.Ticket, :close
          tool "openTicketCount", MyApp.Support.Ticket, :open_count
        end

    The module implements `LiveRender.OpenUI.ToolAdapter`. Hand it to the runtime's host together
    with a context the host builds — never the program:

        LiveRender.OpenUI.ToolHost.call(MyApp.OpenUITools, "listTickets", %{"status" => "open"},
          %{actor: current_user, tenant: current_org.id})

    ## Security model

      * A program can only call the tool names declared with `tool/4`. Each name maps to one
        resource and one action, fixed at compile time. Actions declared `public?: false` are
        refused at compile time.
      * Every Ash call runs with `actor: context[:actor]`, `tenant: context[:tenant]` and
        `authorize?: true`. There is no option to turn authorization off. The Ash context also
        carries `%{openui: %{tool: name}}`, so policies can tell OpenUI calls apart
        (`authorize_if context_equals(...)`, or a custom check).
      * Update and destroy tools locate the record by primary key through a read action
        (`:read_action`, default the primary read) with the same actor and tenant, so read
        policies and tenant isolation apply before the change runs. A record the actor cannot
        read is reported as not found.
      * Inputs are filtered against the action: public arguments and public accepted attributes
        are passed; every other key is **dropped** silently, the way OpenUI drops excess component
        arguments. The multitenancy attribute is never accepted from the program. Read tools take
        no filter, sort or load input; `limit` and `offset` are accepted only when the tool
        declares `pagination: true`, and `limit` is capped by the tool's `:limit`.
      * Results contain public, non-sensitive attributes only, plus the public, non-sensitive
        calculations, aggregates and relationships named in `:load`. Related records follow the
        same rule. A field hidden by a field policy becomes `nil`.
      * Errors never carry Ash internals: `"forbidden"`, `"not found"`, `"invalid input: ..."`
        with field messages, or `"internal error"` (the details go to `Logger`). `call_tool/3`
        never raises.

    ## Tool options

      * `:description` — shown to the model; defaults to the action's description
      * `:read_action` — update/destroy: the read action that locates the record
      * `:fields` — the public attributes (and `:load` names) to return; default all public,
        non-sensitive attributes plus `:load`
      * `:load` — public calculations, aggregates and relationships to load and return
      * `:limit` — read: the maximum number of rows (default 100)
      * `:pagination` — read: when `true`, the program may pass `limit` and `offset`
      * `:result` — read: `:rows` (default) returns `%{"rows" => [...]}`, `:list` returns the list.
        With `pagination: true`, `:rows` also returns `"limit"`, `"offset"` and `"hasMore"`.
        `get?` read actions return one record map, or `nil` when nothing matches.

    ## Results by action type

      * read — see `:result`
      * create, update — the record
      * destroy — the destroyed record
      * generic action — the returned value with records converted as above; `nil` for an action
        without a return type

    Inputs that name the record (`"id"`, or every key of a composite primary key) are required by
    update and destroy tools and listed in the input schema.
    """

    alias LiveRender.OpenUI.AshAdapter.{Errors, Inputs, Output, Tool}

    require Logger

    @doc false
    defmacro __using__(_opts) do
      quote do
        @behaviour LiveRender.OpenUI.ToolAdapter
        import LiveRender.OpenUI.AshAdapter, only: [tool: 3, tool: 4]
        Module.register_attribute(__MODULE__, :live_render_ash_tools, accumulate: true)
        @before_compile LiveRender.OpenUI.AshAdapter
      end
    end

    @doc """
    Declares tool `name` as `action` on `resource`. See the module docs for options.

    Declarations are checked at compile time: the resource must be an Ash resource, the action
    must exist and be public, and every `:fields`/`:load` entry must be public and non-sensitive.
    """
    defmacro tool(name, resource, action, opts \\ []) do
      quote do
        @live_render_ash_tools {unquote(name), unquote(resource), unquote(action), unquote(opts)}
      end
    end

    @doc false
    defmacro __before_compile__(env) do
      tools =
        env.module
        |> Module.get_attribute(:live_render_ash_tools)
        |> Enum.reverse()
        |> Tool.build_all!(env.module)

      quote do
        @doc false
        def __live_render_ash_tools__, do: unquote(Macro.escape(tools))

        @impl LiveRender.OpenUI.ToolAdapter
        def tools(context),
          do: LiveRender.OpenUI.AshAdapter.descriptors(__live_render_ash_tools__(), context)

        @impl LiveRender.OpenUI.ToolAdapter
        def call_tool(name, args, context),
          do: LiveRender.OpenUI.AshAdapter.call(__live_render_ash_tools__(), name, args, context)
      end
    end

    @doc "Tool descriptors with a JSON Schema of each action's inputs."
    @spec descriptors([struct()], map()) :: [LiveRender.OpenUI.ToolAdapter.descriptor()]
    def descriptors(tools, _context) do
      Enum.map(tools, fn tool ->
        %{
          name: tool.name,
          description: tool.description,
          input_schema: Inputs.json_schema(tool)
        }
      end)
    end

    @doc "Runs tool `name`. Returns `{:ok, data}` or `{:error, message}`; never raises."
    @spec call([struct()], String.t(), map(), map()) :: {:ok, term()} | {:error, term()}
    def call(tools, name, args, context) do
      case Enum.find(tools, &(&1.name == name)) do
        nil -> {:error, {:tool_not_found, Enum.map(tools, & &1.name)}}
        tool -> safely(tool, if(is_map(args), do: args, else: %{}), context)
      end
    end

    defp safely(tool, args, context) do
      case run(tool, args, context) do
        {:ok, _} = ok -> ok
        {:error, error} -> {:error, Errors.message(tool, error)}
      end
    rescue
      e -> {:error, Errors.message(tool, e, __STACKTRACE__)}
    catch
      kind, reason ->
        Logger.error("OpenUI tool #{tool.name} failed: #{Exception.format(kind, reason)}")
        {:error, "internal error"}
    end

    defp ash_opts(tool, context) do
      context = if is_map(context), do: context, else: %{}

      [
        actor: Map.get(context, :actor),
        tenant: Map.get(context, :tenant),
        authorize?: true,
        context: %{openui: %{tool: tool.name}}
      ]
    end

    defp run(%Tool{type: :read} = tool, args, context) do
      opts = ash_opts(tool, context)
      {limit, offset} = Inputs.page(tool, args)

      query =
        tool.resource
        |> Ash.Query.for_read(tool.action, Inputs.input(tool, args), opts)
        |> Ash.Query.load(tool.load)
        |> select(tool)

      if tool.result == :one do
        with {:ok, record} <- Ash.read_one(query, opts), do: {:ok, Output.value(record, tool)}
      else
        with {:ok, rows, more?} <- read_page(tool, query, limit, offset, opts) do
          {:ok, read_result(tool, Enum.map(rows, &Output.value(&1, tool)), limit, offset, more?)}
        end
      end
    end

    defp run(%Tool{type: :create} = tool, args, context) do
      opts = ash_opts(tool, context)

      tool.resource
      |> Ash.Changeset.for_create(tool.action, Inputs.input(tool, args), opts)
      |> Ash.create(Keyword.put(opts, :load, tool.load))
      |> output(tool)
    end

    defp run(%Tool{type: :update} = tool, args, context) do
      opts = ash_opts(tool, context)

      with {:ok, record} <- locate(tool, args, opts) do
        record
        |> Ash.Changeset.for_update(tool.action, Inputs.input(tool, args), opts)
        |> Ash.update(Keyword.put(opts, :load, tool.load))
        |> output(tool)
      end
    end

    defp run(%Tool{type: :destroy} = tool, args, context) do
      opts = ash_opts(tool, context)

      with {:ok, record} <- locate(tool, args, opts) do
        record
        |> Ash.Changeset.for_destroy(tool.action, Inputs.input(tool, args), opts)
        |> Ash.destroy(Keyword.put(opts, :return_destroyed?, true))
        |> output(tool)
      end
    end

    defp run(%Tool{type: :action} = tool, args, context) do
      opts = ash_opts(tool, context)

      tool.resource
      |> Ash.ActionInput.for_action(tool.action, Inputs.input(tool, args), opts)
      |> Ash.run_action(opts)
      |> case do
        :ok -> {:ok, nil}
        {:ok, value} -> {:ok, Output.value(value, nil)}
        {:error, _} = error -> error
      end
    end

    defp output({:ok, record}, tool), do: {:ok, Output.value(record, tool)}
    defp output({:error, _} = error, _tool), do: error

    defp locate(tool, args, opts) do
      case Inputs.primary_key(tool, args) do
        {:ok, key} ->
          Ash.get(tool.resource, key, Keyword.put(opts, :action, tool.read_action))

        {:error, missing} ->
          {:error, {:missing_key, missing}}
      end
    end

    defp select(query, %Tool{fields: nil}), do: query

    defp select(query, tool) do
      attributes =
        Enum.filter(tool.fields, &Ash.Resource.Info.attribute(tool.resource, &1))

      Ash.Query.ensure_selected(query, attributes)
    end

    # One row past the limit tells whether more rows exist, without a count query.
    defp read_page(tool, query, limit, offset, opts) do
      action = Ash.Resource.Info.action(tool.resource, tool.action)

      if action.pagination && action.pagination.required? do
        page =
          if action.pagination.offset?, do: [limit: limit, offset: offset], else: [limit: limit]

        with {:ok, page} <- Ash.read(query, Keyword.put(opts, :page, page)),
             do: {:ok, page.results, page.more?}
      else
        query = query |> Ash.Query.limit(limit + 1) |> Ash.Query.offset(offset)

        with {:ok, rows} <- Ash.read(query, Keyword.put(opts, :page, false)),
             do: {:ok, Enum.take(rows, limit), length(rows) > limit}
      end
    end

    defp read_result(%Tool{result: :list}, rows, _limit, _offset, _more?), do: rows

    defp read_result(%Tool{pagination: true}, rows, limit, offset, more?),
      do: %{"rows" => rows, "limit" => limit, "offset" => offset, "hasMore" => more?}

    defp read_result(_tool, rows, _limit, _offset, _more?), do: %{"rows" => rows}
  end
end
