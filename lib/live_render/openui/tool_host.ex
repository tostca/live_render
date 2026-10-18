defmodule LiveRender.OpenUI.ToolHost do
  @moduledoc """
  Runs the tool calls a `LiveRender.OpenUI.Runtime` asks for, against an explicit allowlist.

  `tools` may be:

    * a map of name to function: `%{"listTickets" => fn args -> {:ok, rows} end}`. A 2-arity
      function also receives the host context. A function may return `{:ok, data}`,
      `{:error, reason}`, or a bare value (treated as `{:ok, value}`).
    * a module implementing `LiveRender.OpenUI.ToolAdapter`, or `{module, extra_context}`
    * a list of the above; the first source that lists a name wins
    * nil: no tools

  A name no source lists gives `{:error, {:tool_not_found, available_names}}`; the runtime turns
  that into a `tool-not-found` error whose hint lists the tools. Exceptions and exits in a tool
  become `{:error, message}` and never crash the caller.
  """

  @type source :: map() | module() | {module(), map()}
  @type tools :: source() | [source()] | nil

  @doc "The tool names available in `context`, in source order."
  @spec names(tools(), map()) :: [String.t()]
  def names(tools, context \\ %{}) do
    tools |> descriptors(context) |> Enum.map(& &1.name)
  end

  @doc "Tool descriptors for prompt generation."
  @spec descriptors(tools(), map()) :: [map()]
  def descriptors(tools, context \\ %{}) do
    tools
    |> sources()
    |> Enum.flat_map(&source_descriptors(&1, context))
    |> Enum.uniq_by(& &1.name)
  end

  @doc "Calls tool `name` with `args`. See the module docs for the result shapes."
  @spec call(tools(), String.t(), map(), map()) :: {:ok, term()} | {:error, term()}
  def call(tools, name, args, context \\ %{}) do
    case Enum.find(
           sources(tools),
           &(name in Enum.map(source_descriptors(&1, context), fn d -> d.name end))
         ) do
      nil -> {:error, {:tool_not_found, names(tools, context)}}
      source -> run(source, name, args, context)
    end
  end

  defp sources(nil), do: []
  defp sources(list) when is_list(list), do: list
  defp sources(source), do: [source]

  defp source_descriptors(map, _context) when is_map(map) and not is_struct(map) do
    map |> Map.keys() |> Enum.map(&%{name: to_string(&1)}) |> Enum.sort_by(& &1.name)
  end

  defp source_descriptors({module, extra}, context) when is_atom(module) and is_map(extra),
    do: source_descriptors(module, Map.merge(context, extra))

  defp source_descriptors(module, context) when is_atom(module) do
    module.tools(context) |> Enum.map(&descriptor/1)
  rescue
    _ -> []
  catch
    # A listing that exits or throws must not crash the caller either.
    _kind, _reason -> []
  end

  defp descriptor(name) when is_binary(name), do: %{name: name}
  defp descriptor(%{name: name} = d), do: %{d | name: to_string(name)}

  defp descriptor(%{"name" => name} = d),
    do: %{name: name, description: d["description"], input_schema: d["inputSchema"]}

  defp run(map, name, args, context) when is_map(map) and not is_struct(map) do
    fun =
      Map.get(map, name) || Enum.find_value(map, fn {k, v} -> if to_string(k) == name, do: v end)

    guard(fn -> wrap(if is_function(fun, 2), do: fun.(args, context), else: fun.(args)) end)
  end

  defp run({module, extra}, name, args, context),
    do: run(module, name, args, Map.merge(context, extra))

  defp run(module, name, args, context),
    do: guard(fn -> wrap(module.call_tool(name, args, context)) end)

  defp wrap({:ok, _} = ok), do: ok
  defp wrap({:error, _} = error), do: error
  defp wrap(:ok), do: {:ok, nil}
  defp wrap(other), do: {:ok, other}

  defp guard(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, "exited: #{inspect(reason)}"}
    :throw, value -> {:error, "threw: #{inspect(value)}"}
  end
end
