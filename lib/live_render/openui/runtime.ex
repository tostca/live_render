defmodule LiveRender.OpenUI.Runtime do
  @moduledoc """
  The interactive OpenUI runtime: one rendered program with its state store, queries, mutations
  and action plans (language.md, sections 4 to 6 and 8.3).

  The runtime is a pure state machine. Every operation returns `{runtime, effects}` and the host
  carries out the effects:

    * `{:call_tool, ref, name, args}` — call a tool, then report back with `tool_result/3`
    * `{:schedule, ref, ms}` — call `timer/2` with `ref` after `ms` milliseconds (query refresh)
    * `{:event, event}` — a host event (`continue_conversation`, `open_url`, a custom action)
    * `{:errors, [Error.t()]}` — the error list changed (emitted only when it changes)
    * `{:state, map}` — the user or an action changed state (for persistence)

  Typical use:

      rt = Runtime.new(library, response: text, streaming: false)
      {rt, effects} = Runtime.start(rt)
      Runtime.tree(rt)            #=> evaluated %Element{} tree for rendering
      {rt, effects} = Runtime.click(rt, ["children", 1])
      {rt, effects} = Runtime.input(rt, ["children", 0], "hello")
      {rt, effects} = Runtime.tool_result(rt, ref, {:ok, data})

  Queries and mutations never run while streaming. Tools are called only through effects, so the
  host decides which tools exist and with what authority (see `LiveRender.OpenUI.ToolHost`).
  """

  alias LiveRender.OpenUI.{
    ActionPlan,
    Binding,
    Element,
    Error,
    Evaluator,
    JS,
    Library,
    Rules,
    Store,
    Tree,
    Values
  }

  alias LiveRender.OpenUI.Parser.{Result, Stream}

  defstruct lib: nil,
            stream: nil,
            result: %Result{},
            streaming: false,
            store: %Store{},
            queries: %{},
            mutations: %{},
            tree: nil,
            runtime_errors: [],
            emitted_errors: [],
            next_ref: 1,
            inflight: %{},
            queue: [],
            max_concurrency: 8,
            timers: %{},
            field_errors: %{},
            finalized: false

  @type t :: %__MODULE__{}
  @type effect ::
          {:call_tool, pos_integer(), String.t(), map()}
          | {:schedule, pos_integer(), pos_integer()}
          | {:event, map()}
          | {:errors, [Error.t()]}
          | {:state, map()}

  @idle %{"status" => "idle", "data" => nil, "error" => nil}

  # ── Lifecycle ────────────────────────────────────────────────────────────

  @doc """
  Creates a runtime.

  Options:

    * `:response` — program text received so far (may contain message markers)
    * `:streaming` — whether more text will arrive (default `false`)
    * `:initial_state` — persisted state from the host, applied over declared defaults
    * `:max_concurrency` — tool calls in flight at once (default 8)
  """
  @spec new(Library.t(), keyword()) :: t()
  def new(%Library{} = lib, opts \\ []) do
    rt = %__MODULE__{
      lib: lib,
      stream: Stream.new(lib),
      streaming: Keyword.get(opts, :streaming, false),
      store:
        Store.initialize(
          Store.new(),
          %{},
          opts |> Keyword.get(:initial_state, %{}) |> Values.from_host()
        ),
      max_concurrency: Keyword.get(opts, :max_concurrency, 8)
    }

    {stream, result} = Stream.set(rt.stream, Keyword.get(opts, :response, ""), not rt.streaming)

    %{rt | stream: stream, result: result}
    |> apply_defaults()
    |> evaluate()
  end

  @doc "Starts a mounted runtime. When the stream has already ended, queries run now."
  @spec start(t()) :: {t(), [effect()]}
  def start(%__MODULE__{streaming: true} = rt), do: {rt, []}
  def start(%__MODULE__{} = rt), do: finalize(rt)

  @doc """
  Sets the response text received so far. Text that does not extend the previous text starts a
  new stream, which clears the error list. `streaming: false` ends the stream.
  """
  @spec set_response(t(), String.t(), boolean()) :: {t(), [effect()]}
  def set_response(%__MODULE__{} = rt, text, streaming?) do
    restart? =
      not String.starts_with?(text, Stream.text(rt.stream)) or (not rt.streaming and streaming?)

    {stream, result} = Stream.set(rt.stream, text, not streaming?)

    rt =
      %{
        rt
        | stream: stream,
          result: result,
          streaming: streaming?,
          finalized: rt.finalized and not restart?
      }
      |> apply_defaults()
      |> evaluate()

    {rt, clear} =
      if restart? and rt.emitted_errors != [],
        do: {%{rt | emitted_errors: []}, [{:errors, []}]},
        else: {rt, []}

    if streaming? do
      {rt, clear}
    else
      {rt, effects} = finalize(rt)
      {rt, clear ++ effects}
    end
  end

  @doc "Appends a chunk to a streaming response."
  @spec push(t(), String.t()) :: {t(), [effect()]}
  def push(%__MODULE__{} = rt, chunk), do: set_response(rt, Stream.text(rt.stream) <> chunk, true)

  @doc "Ends the stream: the pending tail is finalized, queries run, and errors are emitted."
  @spec end_stream(t()) :: {t(), [effect()]}
  def end_stream(%__MODULE__{} = rt), do: set_response(rt, Stream.text(rt.stream), false)

  # Stream end: register data statements, start queries, emit errors.
  defp finalize(rt) do
    rt = %{rt | finalized: true} |> register_mutations() |> drop_removed_queries()
    {rt, effects} = sync_queries(rt)
    rt = evaluate(rt)
    {rt, errs} = emit_errors(rt)
    {rt, effects ++ errs}
  end

  # ── Reading ──────────────────────────────────────────────────────────────

  @doc "The evaluated tree, ready to render, or nil."
  @spec tree(t()) :: Element.t() | nil
  def tree(%__MODULE__{tree: tree}), do: tree

  @doc "The parse result of the current program."
  def result(%__MODULE__{result: r}), do: r

  @doc "The state store's map: `$variables` with plain values, form names with their fields."
  @spec state(t()) :: map()
  def state(%__MODULE__{store: s}), do: Store.snapshot(s)

  @doc "True while text is still streaming in."
  def streaming?(%__MODULE__{streaming: s}), do: s

  @doc "The program text received so far."
  def text(%__MODULE__{stream: s}), do: Stream.text(s)

  @doc """
  The current error list (language.md, section 8.3). Parser and runtime errors appear only once the
  stream has ended; tool errors appear when they happen.
  """
  @spec errors(t()) :: [Error.t()]
  def errors(%__MODULE__{streaming: true}), do: []

  def errors(%__MODULE__{} = rt) do
    query_errors = for {_, q} <- rt.queries, q.error, do: q.error
    mutation_errors = for {_, m} <- rt.mutations, m.error, do: m.error
    rt.result.errors ++ rt.runtime_errors ++ query_errors ++ mutation_errors
  end

  @doc """
  Fetch state for the host (the reserved `__openui_loading`, `__openui_refetching` and
  `__openui_errors` keys of section 6.1).
  """
  def query_status(%__MODULE__{} = rt) do
    loading = for {id, q} <- rt.queries, q.in_flight != nil, do: id
    refetching = for {id, q} <- rt.queries, q.in_flight != nil, latest(q) != :none, do: id
    errors = for {_, q} <- rt.queries, q.error, do: q.error

    %{
      "__openui_loading" => loading,
      "__openui_refetching" => refetching,
      "__openui_errors" => errors
    }
  end

  @doc "A mutation's `{status, data, error}` map."
  def mutation(%__MODULE__{} = rt, id),
    do: rt.mutations |> Map.get(id, %{result: nil}) |> Map.get(:result)

  @doc "The validation error of a form field, or nil. `form` is nil for page-level fields."
  def field_error(%__MODULE__{field_errors: errors}, form, name),
    do: Map.get(errors, {form, name})

  @doc """
  The value a field component shows: its bound `$variable`, else its form field value, else its
  static value prop.
  """
  def field_value(%__MODULE__{} = rt, %Element{} = el, form) do
    comp = Library.get_component(rt.lib, el.type_name)
    value_prop = (comp && comp.value_prop) || "value"
    name = field_name(el, comp)

    case Map.get(el.props, value_prop) do
      %Binding{target: t} ->
        unwrap(Store.get(rt.store, t))

      static ->
        case read_field(rt.store, form, name) do
          {:ok, v} -> v
          :error -> static
        end
    end
  end

  # ── Interactions ─────────────────────────────────────────────────────────

  @doc """
  Clicks the component at `path`: runs the action in `prop` (default `"action"`). A component
  with no action sends `continue_conversation` with its label, like the reference button. Inside
  a form, every field must pass its validation rules first.
  """
  @spec click(t(), Tree.path(), String.t()) :: {t(), [effect()]}
  def click(%__MODULE__{} = rt, path, prop \\ "action") do
    case Tree.at_path(rt.tree, rt.lib, path) do
      {:ok, el, form} -> do_click(rt, el, path, form, prop)
      :error -> {rt, []}
    end
  end

  @doc "Clicks the first component that came from statement `id` (used by conformance tests)."
  def click_statement(%__MODULE__{} = rt, id, prop \\ "action") do
    case Tree.find_statement(rt.tree, rt.lib, id) do
      {:ok, el, path, form} -> do_click(rt, el, path, form, prop)
      :error -> {:error, :not_found}
    end
  end

  defp do_click(rt, el, path, form, prop) do
    if rt.streaming or not rt.finalized do
      {rt, []}
    else
      label = el.props |> Map.get("label") |> label_text()

      case validate_form(rt, path, form) do
        {:invalid, rt} ->
          {evaluate(rt), []}

        {:ok, rt} ->
          case Map.get(el.props, prop) do
            %ActionPlan{steps: steps} ->
              run_steps(rt, steps, %{form: form, label: label}, [])

            nil when prop == "action" ->
              {rt, [{:event, event(rt, "continue_conversation", %{}, label, form)}]}

            # Only the action prop has a default and legacy behavior, so a client naming another
            # prop (say "label") cannot make an element send events.
            other when prop == "action" ->
              legacy_action(rt, other, label, form)

            _ ->
              {rt, []}
          end
      end
    end
  end

  defp label_text(nil), do: ""
  defp label_text(v) when is_binary(v), do: v
  defp label_text(v), do: JS.to_string_value(v)

  # A plain list of actions is data, and legacy `{type, params}` objects keep working; a legacy
  # object can never pose as a custom action.
  defp legacy_action(rt, %{"type" => type} = action, label, form) when is_binary(type) do
    if Map.has_key?(rt.lib.actions, type) do
      {rt, []}
    else
      params = Map.get(action, "params") |> then(&if(is_map(&1), do: &1, else: %{}))

      params =
        Enum.reduce(["url", "context"], params, fn k, acc ->
          if action[k], do: Map.put(acc, k, action[k]), else: acc
        end)

      {rt, [{:event, event(rt, type, params, label, form)}]}
    end
  end

  defp legacy_action(rt, _other, label, form),
    do: {rt, [{:event, event(rt, "continue_conversation", %{}, label, form)}]}

  @doc """
  Writes user input into the field component at `path`: its bound `$variable`, or its form field
  (`{value, componentType}`) under the nearest form, or page-level state.
  """
  @spec input(t(), Tree.path(), term()) :: {t(), [effect()]}
  def input(%__MODULE__{} = rt, path, value) do
    case Tree.at_path(rt.tree, rt.lib, path) do
      {:ok, el, form} -> do_input(rt, el, form, value)
      :error -> {rt, []}
    end
  end

  @doc "Types into the first component that came from statement `id`."
  def type_statement(%__MODULE__{} = rt, id, value) do
    case Tree.find_statement(rt.tree, rt.lib, id) do
      {:ok, el, _path, form} -> do_input(rt, el, form, value)
      :error -> {:error, :not_found}
    end
  end

  defp do_input(rt, el, form, value) do
    comp = Library.get_component(rt.lib, el.type_name)
    value = Values.from_host(value)
    value_prop = (comp && comp.value_prop) || "value"
    name = field_name(el, comp)

    store =
      case Map.get(el.props, value_prop) do
        %Binding{target: target, expr: nil} ->
          Store.put(rt.store, target, value)

        %Binding{target: target, expr: expr} ->
          ctx = %{eval_ctx(rt) | scope: %{"$value" => value}}
          Store.put(rt.store, target, safe_eval(expr, ctx))

        _ when is_binary(name) ->
          if field?(comp),
            do: write_field(rt.store, form, name, value, comp.field || downcase(el.type_name)),
            else: :none

        _ ->
          :none
      end

    # Input aimed at something that holds no value (a button, a form) changes nothing.
    if store == :none do
      {rt, []}
    else
      rt = %{rt | store: store} |> revalidate_field(el, comp, form, value)
      state_changed(rt, [])
    end
  end

  # A field writes form state: a library field component, or one with a value prop.
  defp field?(nil), do: false

  defp field?(comp),
    do: comp.field != nil or Enum.any?(comp.params, &(&1.name == comp.value_prop))

  defp downcase(name), do: String.downcase(name)

  defp field_name(el, comp) do
    case Map.get(el.props, (comp && comp.name_prop) || "name") do
      n when is_binary(n) and n != "" -> n
      _ -> nil
    end
  end

  defp write_field(store, nil, name, value, type),
    do: Store.put(store, name, %{"value" => value, "componentType" => type})

  defp write_field(store, form, name, value, type) do
    fields =
      case Store.get(store, form) do
        m when is_map(m) -> m
        _ -> %{}
      end

    Store.put(store, form, Map.put(fields, name, %{"value" => value, "componentType" => type}))
  end

  defp read_field(store, nil, name) when is_binary(name) do
    if Store.has?(store, name), do: {:ok, unwrap(Store.get(store, name))}, else: :error
  end

  defp read_field(store, form, name) when is_binary(name) do
    case Store.get(store, form) do
      %{^name => v} -> {:ok, unwrap(v)}
      _ -> :error
    end
  end

  defp read_field(_store, _form, _name), do: :error

  defp unwrap(%{"value" => v, "componentType" => _}), do: v
  defp unwrap(v), do: v

  # ── Validation ───────────────────────────────────────────────────────────

  # A form submits only when every field passes (section 5.4). Clicks outside a form never block.
  defp validate_form(rt, _path, nil), do: {:ok, rt}

  defp validate_form(rt, _path, form) do
    fields =
      for {el, _p, ^form} <- Tree.elements(rt.tree, rt.lib),
          comp = Library.get_component(rt.lib, el.type_name),
          comp && (comp.field || MapSet.member?(comp.bindable, comp.value_prop)),
          rules = Map.get(el.props, comp.rules_prop),
          is_map(rules),
          name = field_name(el, comp),
          do: {name, Rules.validate(field_value(rt, el, form), rules)}

    errors =
      Enum.reduce(fields, rt.field_errors, fn {name, err}, acc ->
        if err, do: Map.put(acc, {form, name}, err), else: Map.delete(acc, {form, name})
      end)

    rt = %{rt | field_errors: errors}
    if Enum.any?(fields, fn {_, err} -> err end), do: {:invalid, rt}, else: {:ok, rt}
  end

  # An error shown on a field clears as soon as the new value passes.
  defp revalidate_field(rt, el, comp, form, value) do
    name = comp && field_name(el, comp)

    with true <- name != nil,
         true <- Map.has_key?(rt.field_errors, {form, name}),
         rules when is_map(rules) <- Map.get(el.props, comp.rules_prop) do
      case Rules.validate(value, rules) do
        nil -> %{rt | field_errors: Map.delete(rt.field_errors, {form, name})}
        err -> %{rt | field_errors: Map.put(rt.field_errors, {form, name}, err)}
      end
    else
      _ -> rt
    end
  end

  # ── Action plans ─────────────────────────────────────────────────────────

  # Actions run in order. A mutation run is awaited: the plan suspends until its result arrives.
  # Query fetches and host events are sent without waiting.
  defp run_steps(rt, [], _plan, effects), do: {rt, effects}

  defp run_steps(rt, [step | rest], plan, effects) do
    case step do
      {:run, id, :mutation} ->
        run_mutation(rt, id, rest, plan, effects)

      {:run, id, :query} ->
        {rt, fx} = refetch(rt, id)
        run_steps(rt, rest, plan, effects ++ fx)

      {:continue_conversation, msg, context} ->
        params = if context == :none, do: %{}, else: %{"context" => JS.to_json(context)}

        run_steps(
          rt,
          rest,
          plan,
          effects ++ [{:event, event(rt, "continue_conversation", params, msg, plan.form)}]
        )

      {:open_url, url} ->
        run_steps(
          rt,
          rest,
          plan,
          effects ++ [{:event, event(rt, "open_url", %{"url" => url}, "", plan.form)}]
        )

      {:custom, name, params, _order} ->
        run_steps(
          rt,
          rest,
          plan,
          effects ++ [{:event, event(rt, name, JS.to_json(params), "", plan.form)}]
        )

      {:set, target, ast} ->
        value = safe_eval(ast, eval_ctx(rt))

        {rt, fx} =
          state_changed(%{rt | store: Store.put(rt.store, target, Values.from_host(value))}, [])

        run_steps(rt, rest, plan, effects ++ fx)

      {:reset, targets} ->
        store =
          Enum.reduce(targets, rt.store, fn t, s ->
            Store.put(s, t, Map.get(rt.result.state, t), pristine: true)
          end)

        {rt, fx} = state_changed(%{rt | store: store}, [])
        run_steps(rt, rest, plan, effects ++ fx)
    end
  end

  defp run_mutation(rt, id, rest, plan, effects) do
    case rt.mutations[id] do
      # While loading, a second run is rejected and the plan stops.
      nil ->
        {rt, effects}

      %{result: %{"status" => "loading"}} ->
        {rt, effects}

      m ->
        decl = Enum.find(rt.result.mutations, &(&1.id == id))

        args =
          case decl && decl.args && safe_eval(decl.args, eval_ctx(rt)) do
            map when is_map(map) and not is_struct(map) -> map
            _ -> %{}
          end

        loading = %{m | result: %{"status" => "loading", "data" => nil, "error" => nil}}
        rt = %{rt | mutations: Map.put(rt.mutations, id, loading)}
        {rt, fx} = call_tool(rt, {:mutation, id, rest, plan}, m.tool, args)
        {evaluate(rt), effects ++ fx}
    end
  end

  # Each event carries the form state as of when its action runs (section 6.3).
  defp event(rt, type, params, message, form) do
    base = %{
      "type" => type,
      "params" => params,
      "humanFriendlyMessage" => message,
      "formState" => form_state(rt, form)
    }

    if form, do: Map.put(base, "formName", form), else: base
  end

  # Inside a form, only that form's fields, even before any were written: the reference falls
  # back to the whole store there, but section 6.3 scopes form state to the form.
  defp form_state(rt, nil), do: JS.to_json(Store.snapshot(rt.store))

  defp form_state(rt, form) do
    case Store.get(rt.store, form) do
      fields when is_map(fields) -> JS.to_json(%{form => fields})
      _ -> %{form => %{}}
    end
  end

  # ── Queries ──────────────────────────────────────────────────────────────

  defp drop_removed_queries(rt) do
    ids = MapSet.new(rt.result.queries, & &1.id)
    %{rt | queries: Map.filter(rt.queries, fn {id, _} -> MapSet.member?(ids, id) end)}
  end

  defp register_mutations(rt) do
    ctx = eval_ctx(rt)

    mutations =
      Map.new(rt.result.mutations, fn m ->
        tool = tool_name(m.tool, ctx)

        case rt.mutations[m.id] do
          %{tool: ^tool} = existing -> {m.id, existing}
          _ -> {m.id, %{tool: tool, result: @idle, error: nil}}
        end
      end)

    %{rt | mutations: mutations}
  end

  defp tool_name(nil, _ctx), do: ""

  defp tool_name(ast, ctx) do
    case safe_eval(ast, ctx) do
      s when is_binary(s) -> s
      nil -> ""
      other -> JS.to_string_value(other)
    end
  end

  # A query fetches when its key changes: the tool, its statement, and the values of the
  # `$variables` written literally in its args (section 6.1).
  defp sync_queries(%__MODULE__{streaming: true} = rt), do: {rt, []}
  defp sync_queries(%__MODULE__{finalized: false} = rt), do: {rt, []}

  defp sync_queries(rt) do
    ctx = eval_ctx(rt)

    Enum.reduce(rt.result.queries, {rt, []}, fn q, {rt, effects} ->
      tool = tool_name(q.tool, ctx)
      key = {q.fingerprint, tool, Enum.map(q.deps, &Store.get(rt.store, &1))}
      refresh_ms = refresh_ms(q.refresh, ctx)

      {rt, fx1} =
        case rt.queries[q.id] do
          %{key: ^key, needs_refetch: true, in_flight: nil} ->
            fetch(put_query(rt, q.id, %{rt.queries[q.id] | needs_refetch: false}), q.id)

          %{key: ^key} ->
            {rt, []}

          existing ->
            entry = %{
              key: key,
              tool: tool,
              data: :none,
              last_good: if(existing, do: latest(existing), else: :none),
              in_flight: nil,
              needs_refetch: false,
              # An error stays until the new fetch settles, so the error list does not flicker.
              error: existing && existing.error,
              refresh_ms: if(existing, do: existing.refresh_ms, else: 0),
              timer: if(existing, do: existing.timer)
            }

            fetch(%{rt | queries: Map.put(rt.queries, q.id, entry)}, q.id)
        end

      {rt, fx2} = configure_refresh(rt, q.id, refresh_ms)
      {rt, effects ++ fx1 ++ fx2}
    end)
  end

  defp latest(%{data: {:ok, _} = d}), do: d
  defp latest(%{last_good: lg}), do: lg

  defp refresh_ms(nil, _ctx), do: 0

  defp refresh_ms(ast, ctx) do
    case JS.to_number(safe_eval(ast, ctx)) do
      n when is_number(n) and n > 0 -> max(trunc(n * 1000), 1000)
      _ -> 0
    end
  end

  defp configure_refresh(rt, id, ms) do
    q = rt.queries[id]

    cond do
      q.refresh_ms == ms ->
        {rt, []}

      ms == 0 ->
        {put_query(rt, id, %{q | refresh_ms: 0, timer: nil}), []}

      true ->
        ref = rt.next_ref
        rt = %{rt | next_ref: ref + 1, timers: Map.put(rt.timers, ref, id)}
        {put_query(rt, id, %{q | refresh_ms: ms, timer: ref}), [{:schedule, ref, ms}]}
    end
  end

  @doc """
  A refresh timer fired. Refetches the query unless a fetch is in flight or a new stream is
  streaming, then reschedules.
  """
  @spec timer(t(), pos_integer()) :: {t(), [effect()]}
  def timer(%__MODULE__{} = rt, ref) do
    {id, timers} = Map.pop(rt.timers, ref)
    rt = %{rt | timers: timers}

    case id && rt.queries[id] do
      %{timer: ^ref, refresh_ms: ms} = q when ms > 0 ->
        # Queries never run while streaming (section 4, rule 6); the timer keeps ticking.
        {rt, fx} =
          if q.in_flight || not runnable?(rt), do: {rt, []}, else: fetch(rt, id)

        next = rt.next_ref
        rt = %{rt | next_ref: next + 1, timers: Map.put(rt.timers, next, id)}
        rt = put_query(rt, id, %{rt.queries[id] | timer: next})
        {rt, fx ++ [{:schedule, next, ms}]}

      _ ->
        {rt, []}
    end
  end

  # @Run(query): fetch again, or once more after the current fetch when one is in flight. While a
  # new stream is streaming, the fetch waits for the stream end.
  defp refetch(rt, id) do
    case rt.queries[id] do
      nil -> {rt, []}
      %{in_flight: nil} = q -> if runnable?(rt), do: fetch(rt, id), else: mark_refetch(rt, id, q)
      q -> mark_refetch(rt, id, q)
    end
  end

  defp mark_refetch(rt, id, q), do: {put_query(rt, id, %{q | needs_refetch: true}), []}

  defp runnable?(rt), do: rt.finalized and not rt.streaming

  defp fetch(rt, id) do
    q = rt.queries[id]
    decl = Enum.find(rt.result.queries, &(&1.id == id))

    args =
      case decl && decl.args && safe_eval(decl.args, eval_ctx(rt)) do
        map when is_map(map) and not is_struct(map) -> map
        _ -> %{}
      end

    {rt, fx} = call_tool(rt, {:query, id, q.key}, q.tool, args)
    ref = rt.next_ref - 1
    {put_query(rt, id, %{rt.queries[id] | in_flight: ref}), fx}
  end

  defp put_query(rt, id, q), do: %{rt | queries: Map.put(rt.queries, id, q)}

  # ── Tool calls ───────────────────────────────────────────────────────────

  defp call_tool(rt, purpose, tool, args) do
    ref = rt.next_ref
    rt = %{rt | next_ref: ref + 1, inflight: Map.put(rt.inflight, ref, purpose)}
    args = JS.to_json(args)
    running = map_size(rt.inflight) - length(rt.queue)

    if running > rt.max_concurrency,
      do: {%{rt | queue: rt.queue ++ [{ref, tool, args}]}, []},
      else: {rt, [{:call_tool, ref, tool, args}]}
  end

  @doc """
  Reports a tool call's result: `{:ok, data}`, `{:error, {:tool_not_found, available_names}}`,
  `{:error, {:mcp_error, text}}` or `{:error, reason}`.
  """
  @spec tool_result(t(), pos_integer(), {:ok, term()} | {:error, term()}) :: {t(), [effect()]}
  def tool_result(%__MODULE__{} = rt, ref, result) do
    {purpose, inflight} = Map.pop(rt.inflight, ref)
    rt = %{rt | inflight: inflight}
    {rt, released} = release_queue(rt)

    {rt, effects} =
      case purpose do
        nil -> {rt, []}
        {:query, id, key} -> query_result(rt, id, key, ref, result)
        {:mutation, id, rest, plan} -> mutation_result(rt, id, rest, plan, result)
      end

    {rt, errs} = emit_errors(rt)
    {rt, released ++ effects ++ errs}
  end

  defp release_queue(%{queue: []} = rt), do: {rt, []}

  defp release_queue(rt) do
    running = map_size(rt.inflight) - length(rt.queue)

    if running < rt.max_concurrency do
      [{ref, tool, args} | rest] = rt.queue
      {rt, fx} = release_queue(%{rt | queue: rest})
      {rt, [{:call_tool, ref, tool, args} | fx]}
    else
      {rt, []}
    end
  end

  defp query_result(rt, id, key, ref, result) do
    case rt.queries[id] do
      # The query moved to new arguments, or was removed: this result is stale.
      %{key: ^key, in_flight: ^ref} = q ->
        q =
          case result do
            {:ok, data} ->
              %{q | data: {:ok, Values.from_host(data)}, last_good: :none, error: nil}

            {:error, reason} ->
              %{q | error: tool_error(:query, id, q.tool, reason)}
          end

        q = %{q | in_flight: nil}
        rt = put_query(rt, id, q)

        {rt, fx} =
          if q.needs_refetch and runnable?(rt),
            do: fetch(put_query(rt, id, %{q | needs_refetch: false}), id),
            else: {rt, []}

        {evaluate(rt), fx}

      _ ->
        {rt, []}
    end
  end

  defp mutation_result(rt, id, rest, plan, result) do
    case rt.mutations[id] do
      nil ->
        {rt, []}

      m ->
        case result do
          {:ok, data} ->
            m = %{
              m
              | result: %{"status" => "success", "data" => Values.from_host(data), "error" => nil},
                error: nil
            }

            rt = evaluate(%{rt | mutations: Map.put(rt.mutations, id, m)})
            run_steps(rt, rest, plan, [])

          # A failed mutation stops the remaining actions.
          {:error, reason} ->
            error = tool_error(:mutation, id, m.tool, reason)

            m = %{
              m
              | result: %{"status" => "error", "data" => nil, "error" => error.message},
                error: error
            }

            {evaluate(%{rt | mutations: Map.put(rt.mutations, id, m)}), []}
        end
    end
  end

  defp tool_error(source, id, tool, reason) do
    {code, message, hint} =
      case reason do
        {:tool_not_found, available} ->
          hint = if available != [], do: "Available tools: " <> Enum.join(available, ", ")
          {"tool-not-found", "#{label(source)} tool \"#{tool}\" not found", hint}

        {:mcp_error, text} ->
          {"mcp-error", "#{label(source)} \"#{tool}\" returned an error: #{text}", nil}

        other ->
          {"tool-error", "#{label(source)} \"#{tool}\" failed: #{describe(other)}", nil}
      end

    %Error{
      source: source,
      code: code,
      message: message,
      statement_id: id,
      component: label(source),
      tool_name: tool,
      hint: hint
    }
  end

  defp label(:query), do: "Query"
  defp label(:mutation), do: "Mutation"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(reason), do: inspect(reason)

  # ── Evaluation ───────────────────────────────────────────────────────────

  # Declared defaults apply when a key has no value yet or still holds a pristine default.
  defp apply_defaults(rt), do: %{rt | store: Store.initialize(rt.store, rt.result.state)}

  defp state_changed(rt, effects) do
    rt = evaluate(rt)
    {rt, fx} = sync_queries(rt)
    {rt, errs} = emit_errors(rt)
    {rt, effects ++ fx ++ errs ++ [{:state, Store.snapshot(rt.store)}]}
  end

  defp evaluate(rt) do
    {tree, errors} = Evaluator.evaluate_root(rt.result, eval_ctx(rt))
    %{rt | tree: tree, runtime_errors: errors}
  end

  @doc false
  def eval_ctx(rt) do
    store = rt.store

    Evaluator.ctx(
      rt.lib,
      fn name -> unwrap(Store.get(store, name)) end,
      fn name -> resolve(rt, name) end
    )
  end

  @resolving :openui_resolving

  # References to query statements read the latest result, or the defaults before the first one.
  # References to mutations read {status, data, error}.
  defp resolve(rt, name) do
    resolving = Process.get(@resolving, MapSet.new())

    if MapSet.member?(resolving, name) do
      nil
    else
      Process.put(@resolving, MapSet.put(resolving, name))

      try do
        do_resolve(rt, name)
      after
        Process.put(@resolving, resolving)
      end
    end
  end

  defp do_resolve(rt, name) do
    case rt.queries[name] do
      %{data: {:ok, data}} ->
        data

      %{last_good: {:ok, data}} ->
        data

      _ ->
        cond do
          m = rt.mutations[name] ->
            m.result

          q = Enum.find(rt.result.queries, &(&1.id == name)) ->
            if q.defaults, do: Evaluator.eval(q.defaults, eval_ctx(rt)), else: nil

          Enum.any?(rt.result.mutations, &(&1.id == name)) ->
            @idle

          true ->
            nil
        end
    end
  end

  defp safe_eval(ast, ctx) do
    Evaluator.eval(ast, ctx)
  rescue
    _ -> nil
  catch
    :throw, {:openui_budget, _} -> nil
  end

  # The error list is emitted only when it changes (section 8.3).
  defp emit_errors(rt) do
    current = errors(rt)

    if current == rt.emitted_errors,
      do: {rt, []},
      else: {%{rt | emitted_errors: current}, [{:errors, current}]}
  end
end
