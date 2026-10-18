if Code.ensure_loaded?(Ash) do
  defmodule LiveRender.OpenUI.AshAdapter.Tool do
    @moduledoc false
    # One allowlisted tool: a name bound to a resource action, checked when the adapter module
    # compiles. Everything here is fixed at compile time; nothing comes from the program.

    alias Ash.Resource.Info

    @enforce_keys [:name, :resource, :action, :type]
    defstruct [
      :name,
      :resource,
      :action,
      :type,
      :description,
      :read_action,
      :fields,
      load: [],
      limit: 100,
      pagination: false,
      result: :rows
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            resource: module(),
            action: atom(),
            type: :read | :create | :update | :destroy | :action,
            description: String.t(),
            read_action: atom() | nil,
            fields: [atom()] | nil,
            load: [atom()],
            limit: pos_integer(),
            pagination: boolean(),
            result: :rows | :list | :one
          }

    @options [:description, :read_action, :fields, :load, :limit, :pagination, :result]

    def build_all!(declarations, module) do
      tools = Enum.map(declarations, &build!(&1, module))

      case tools |> Enum.frequencies_by(& &1.name) |> Enum.find(fn {_, n} -> n > 1 end) do
        nil -> tools
        {name, _} -> fail!(module, name, "is declared more than once")
      end
    end

    defp build!({name, resource, action_name, opts}, module) do
      check_declaration!(name, opts, module)
      action = fetch_action!(name, resource, action_name, module)

      tool = %__MODULE__{
        name: name,
        resource: resource,
        action: action_name,
        type: action.type,
        description: opts[:description] || action.description || describe(resource, action),
        load: List.wrap(opts[:load]),
        fields: opts[:fields] && List.wrap(opts[:fields]),
        limit: Keyword.get(opts, :limit, 100),
        pagination: Keyword.get(opts, :pagination, false),
        result: opts[:result] || if(Map.get(action, :get?), do: :one, else: :rows)
      }

      tool
      |> check_read_options!(action, opts, module)
      |> put_read_action!(opts, module)
      |> check_fields!(module)
    end

    defp check_declaration!(name, opts, module) do
      unless is_binary(name) and name != "",
        do: raise(ArgumentError, "#{inspect(module)}: tool names must be non-empty strings")

      unless Keyword.keyword?(opts), do: fail!(module, name, "options must be a keyword list")

      case Keyword.keys(opts) -- @options do
        [] -> :ok
        unknown -> fail!(module, name, "unknown options #{inspect(unknown)}")
      end
    end

    defp fetch_action!(name, resource, action_name, module) do
      Code.ensure_compiled!(resource)

      unless Info.resource?(resource),
        do: fail!(module, name, "#{inspect(resource)} is not an Ash resource")

      case Info.action(resource, action_name) do
        nil ->
          fail!(module, name, "#{inspect(resource)} has no action #{inspect(action_name)}")

        %{public?: false} ->
          fail!(module, name, "action #{inspect(action_name)} is not public")

        action ->
          action
      end
    end

    defp check_read_options!(%{type: :read} = tool, action, opts, module) do
      unless is_integer(tool.limit) and tool.limit > 0,
        do: fail!(module, tool.name, ":limit must be a positive integer")

      unless is_boolean(tool.pagination),
        do: fail!(module, tool.name, ":pagination must be a boolean")

      unless tool.result in [:rows, :list, :one],
        do: fail!(module, tool.name, ":result must be :rows, :list or :one")

      if opts[:result] == :one and not Map.get(action, :get?, false),
        do: fail!(module, tool.name, "result: :one needs a get? read action")

      if tool.pagination, do: check_pagination!(tool, action, module)

      tool
    end

    defp check_read_options!(tool, _action, opts, module) do
      case Keyword.take(opts, [:limit, :pagination, :result]) do
        [] ->
          tool

        given ->
          fail!(module, tool.name, "#{inspect(Keyword.keys(given))} apply to read actions only")
      end
    end

    defp check_pagination!(tool, action, module) do
      if Enum.any?(action.arguments, &(&1.name in [:limit, :offset])),
        do: fail!(module, tool.name, "pagination: true clashes with a limit/offset argument")

      pagination = action.pagination

      if pagination && pagination.required? && !pagination.offset?,
        do: fail!(module, tool.name, "pagination: true needs offset pagination on the action")
    end

    defp put_read_action!(%{type: type} = tool, opts, module) when type in [:update, :destroy] do
      if Info.primary_key(tool.resource) == [],
        do: fail!(module, tool.name, "#{inspect(tool.resource)} has no primary key")

      read_action =
        case opts[:read_action] do
          nil -> Info.primary_action(tool.resource, :read)
          name -> Info.action(tool.resource, name)
        end

      case read_action do
        %{type: :read, name: name} -> %{tool | read_action: name}
        _ -> fail!(module, tool.name, "needs a read action to locate the record (:read_action)")
      end
    end

    defp put_read_action!(tool, opts, module) do
      if opts[:read_action],
        do: fail!(module, tool.name, ":read_action applies to update and destroy actions only")

      tool
    end

    defp check_fields!(tool, module) do
      if tool.type == :destroy and tool.load != [],
        do: fail!(module, tool.name, ":load does not apply to destroy actions")

      for name <- tool.load do
        case loadable(tool.resource, name) do
          :ok -> :ok
          {:error, why} -> fail!(module, tool.name, ":load #{inspect(name)} #{why}")
        end
      end

      for name <- tool.fields || [], name not in tool.load do
        case Info.attribute(tool.resource, name) do
          %{public?: true, sensitive?: false} ->
            :ok

          nil ->
            fail!(module, tool.name, ":fields #{inspect(name)} is not an attribute or in :load")

          _ ->
            fail!(module, tool.name, ":fields #{inspect(name)} is private or sensitive")
        end
      end

      tool
    end

    defp loadable(resource, name) do
      field =
        Info.calculation(resource, name) || Info.aggregate(resource, name) ||
          Info.relationship(resource, name)

      cond do
        not is_atom(name) -> {:error, "must be an atom"}
        is_nil(field) -> {:error, "is not a calculation, aggregate or relationship"}
        not field.public? -> {:error, "is not public"}
        Map.get(field, :sensitive?, false) -> {:error, "is sensitive"}
        true -> :ok
      end
    end

    defp describe(resource, action) do
      short = resource |> Module.split() |> List.last()

      case action.type do
        :read -> if action.get?, do: "Gets a #{short}", else: "Lists #{short} records"
        :create -> "Creates a #{short}"
        :update -> "Updates a #{short} (#{action.name})"
        :destroy -> "Deletes a #{short}"
        :action -> "Runs #{short}.#{action.name}"
      end
    end

    defp fail!(module, name, message) do
      raise ArgumentError, "#{inspect(module)}: tool #{inspect(name)} #{message}"
    end
  end
end
