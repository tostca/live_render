defmodule LiveRender.OpenUI.RuntimeHarness do
  @moduledoc """
  Drives a `LiveRender.OpenUI.Runtime` synchronously in tests, with scripted tools.

  `tools` maps a tool name to:

    * `:hold` — the call stays pending until `deliver/3` reports its result
    * a 1-arity function of the args, returning `{:ok, data}`, `{:error, reason}` or a bare value
    * `{:ok, data}` or `{:error, reason}` — returned as is; any other value as `{:ok, value}`

  A name not in the map gives `{:error, {:tool_not_found, sorted_names}}`. Every effect is
  recorded: `calls` (`%{ref, tool, args}`), `events`, `errors` (each emitted list), `states`
  and `timers` (`ref => ms`), all in emission order.
  """

  alias LiveRender.OpenUI.{Conformance, JS, Runtime, Tree}

  defstruct rt: nil,
            tools: %{},
            pending: %{},
            calls: [],
            events: [],
            errors: [],
            states: [],
            timers: %{},
            effects: []

  @doc "Mounts `text` (ended stream unless `streaming: true`) and runs the start effects."
  def mount(text, opts \\ []) do
    {lib, opts} = Keyword.pop_lazy(opts, :lib, &Conformance.library/0)
    {tools, opts} = Keyword.pop(opts, :tools, %{})
    rt = Runtime.new(lib, Keyword.put(opts, :response, text))
    run(%__MODULE__{tools: tools}, Runtime.start(rt))
  end

  @doc "Runs `fun.(runtime)` and executes the effects it returns."
  def step(%__MODULE__{} = h, fun), do: run(h, fun.(h.rt))

  @doc "Replaces the scripted result of a tool."
  def put_tool(%__MODULE__{} = h, name, spec), do: %{h | tools: Map.put(h.tools, name, spec)}

  @doc "Executes `{runtime, effects}` in order."
  def run(%__MODULE__{} = h, {rt, effects}) do
    Enum.reduce(effects, %{h | rt: rt}, &apply_effect(&2, &1))
  end

  defp apply_effect(h, effect) do
    h = %{h | effects: h.effects ++ [effect]}

    case effect do
      {:event, event} ->
        %{h | events: h.events ++ [JS.to_json(event)]}

      {:errors, list} ->
        %{h | errors: h.errors ++ [list]}

      {:state, map} ->
        %{h | states: h.states ++ [map]}

      {:schedule, ref, ms} ->
        %{h | timers: Map.put(h.timers, ref, ms)}

      {:call_tool, ref, name, args} ->
        h = %{h | calls: h.calls ++ [%{ref: ref, tool: name, args: args}]}

        case Map.fetch(h.tools, name) do
          {:ok, :hold} ->
            %{h | pending: Map.put(h.pending, ref, name)}

          {:ok, fun} when is_function(fun, 1) ->
            run(h, Runtime.tool_result(h.rt, ref, wrap(fun.(args))))

          {:ok, value} ->
            run(h, Runtime.tool_result(h.rt, ref, wrap(value)))

          :error ->
            missing = {:error, {:tool_not_found, h.tools |> Map.keys() |> Enum.sort()}}
            run(h, Runtime.tool_result(h.rt, ref, missing))
        end
    end
  end

  defp wrap({:ok, _} = r), do: r
  defp wrap({:error, _} = r), do: r
  defp wrap(v), do: {:ok, v}

  @doc "Delivers the result of the pending call `ref`."
  def deliver(%__MODULE__{} = h, ref, result) do
    unless Map.has_key?(h.pending, ref), do: raise("no pending call #{ref}")
    h = %{h | pending: Map.delete(h.pending, ref)}
    run(h, Runtime.tool_result(h.rt, ref, result))
  end

  @doc "The refs of pending calls, oldest first, optionally only for `tool`."
  def pending_refs(%__MODULE__{} = h, tool \\ nil) do
    h.pending
    |> Enum.filter(fn {_ref, name} -> tool == nil or name == tool end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc "Fires refresh timer `ref`."
  def fire(%__MODULE__{} = h, ref) do
    h = %{h | timers: Map.delete(h.timers, ref)}
    run(h, Runtime.timer(h.rt, ref))
  end

  @doc "Clears the recorded effects, keeping the runtime and pending calls."
  def reset(%__MODULE__{} = h),
    do: %{h | calls: [], events: [], errors: [], states: [], timers: %{}, effects: []}

  @doc "The tree path of the first element that came from statement `id`."
  def path(%__MODULE__{rt: rt}, id) do
    {:ok, _el, path, _form} = Tree.find_statement(Runtime.tree(rt), rt.lib, id)
    path
  end

  @doc "Clicks statement `id` through its tree path."
  def click(%__MODULE__{} = h, id, prop \\ "action"),
    do: run(h, Runtime.click(h.rt, path(h, id), prop))

  @doc "Types `value` into statement `id` through its tree path."
  def input(%__MODULE__{} = h, id, value), do: run(h, Runtime.input(h.rt, path(h, id), value))

  @doc "Pushes a chunk of a streaming response."
  def push(%__MODULE__{} = h, chunk), do: run(h, Runtime.push(h.rt, chunk))

  @doc "Ends the stream."
  def end_stream(%__MODULE__{} = h), do: run(h, Runtime.end_stream(h.rt))

  @doc "The tool names called, in order."
  def call_names(%__MODULE__{calls: calls}), do: Enum.map(calls, & &1.tool)

  @doc "The state store."
  def state(%__MODULE__{rt: rt}), do: Runtime.state(rt)

  @doc "The summarized tree (fixture shape)."
  def summary(%__MODULE__{rt: rt}) do
    Conformance.summarize(Runtime.tree(rt), Runtime.eval_ctx(rt))
  end

  @doc "The summarized props of the first element from statement `id`."
  def props(%__MODULE__{rt: rt}, id) do
    {:ok, el, _path, _form} = Tree.find_statement(Runtime.tree(rt), rt.lib, id)
    Conformance.summarize(el, Runtime.eval_ctx(rt))["props"]
  end

  @doc "The error codes of the runtime's current error list."
  def error_codes(%__MODULE__{rt: rt}), do: Enum.map(Runtime.errors(rt), & &1.code)
end
