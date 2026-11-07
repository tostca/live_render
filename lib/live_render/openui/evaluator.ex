defmodule LiveRender.OpenUI.Evaluator do
  @moduledoc """
  Evaluates materialized ASTs (language.md, sections 3, 5.2 and 6.3).

  `eval/2` turns one AST node into a value. `evaluate_root/2` evaluates the entry element's props,
  turning `$variables` passed to bindable props into `%Binding{}` structs, and collects
  `runtime-error`s: a prop whose evaluation fails becomes null (section 8.2).

  The context supplies state and references:

      %Evaluator.Ctx{
        lib: library,
        get_state: fn "$name" -> value end,
        resolve_ref: fn "queryName" -> result end
      }
  """

  alias LiveRender.OpenUI.{
    ActionPlan,
    Binding,
    Builtins,
    Element,
    Error,
    JS,
    Library,
    Materializer,
    Validation,
    Values
  }

  defmodule Ctx do
    @moduledoc false
    defstruct lib: nil, get_state: nil, resolve_ref: nil, scope: %{}

    @type t :: %__MODULE__{
            lib: LiveRender.OpenUI.Library.t() | nil,
            get_state: (String.t() -> term()),
            resolve_ref: (String.t() -> term()),
            scope: map()
          }
  end

  @errors_key :openui_eval_errors
  @prop_key :openui_eval_prop
  @steps_key :openui_eval_steps
  @max_steps 500_000
  @max_each 10_000

  @doc "Builds an evaluation context."
  def ctx(lib, get_state, resolve_ref) do
    %Ctx{lib: lib, get_state: get_state, resolve_ref: resolve_ref}
  end

  @doc """
  Evaluates a state default once (section 5.1): `$names` read `declared` (the defaults declared
  before it) and references to query or mutation results read null.
  """
  def constant(ast, lib, declared \\ %{}) do
    eval(ast, ctx(lib, &Map.get(declared, &1), fn _ -> nil end))
  rescue
    _ -> nil
  catch
    :throw, {:openui_budget, _} -> nil
  end

  # ── Tree evaluation ──────────────────────────────────────────────────────

  @doc """
  Evaluates the entry of a parse result. Returns `{element | nil, runtime_errors}`.
  """
  @spec evaluate_root(LiveRender.OpenUI.Parser.Result.t(), Ctx.t()) ::
          {Element.t() | nil, [Error.t()]}
  def evaluate_root(result, ctx) do
    collect(fn ->
      cond do
        result.root -> evaluate_element(result.root, ctx)
        result.root_expression -> evaluate_root_expression(result.root_expression, ctx)
        true -> nil
      end
    end)
  end

  # A runtime entry such as `root = $t ? A : B` must give a component (section 2.2).
  defp evaluate_root_expression(ast, ctx) do
    case guarded(fn -> eval(ast, ctx) end) do
      {:ok, %Element{} = el} ->
        evaluate_element(el, ctx)

      _ ->
        push_error(%Error{
          source: :runtime,
          code: "no-root",
          statement_id: "root",
          message: "root does not evaluate to a component"
        })

        nil
    end
  end

  @doc "Evaluates a value that may hold AST nodes, as a prop would be. Returns `{value, errors}`."
  def evaluate_value(value, ctx, bindable? \\ false) do
    collect(fn -> eval_prop(value, bindable?, ctx) end)
  end

  defp collect(fun) do
    previous = {Process.get(@errors_key), Process.get(@steps_key), Process.get(@prop_key)}
    Process.put(@errors_key, [])
    Process.put(@steps_key, 0)

    try do
      value = fun.()
      {value, Enum.reverse(Process.get(@errors_key))}
    after
      {errors, steps, prop} = previous
      restore(@errors_key, errors)
      restore(@steps_key, steps)
      restore(@prop_key, prop)
    end
  end

  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, value), do: Process.put(key, value)

  defp guarded(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, e}
  catch
    :throw, {:openui_budget, _} = e -> {:error, e}
  end

  defp evaluate_element(%Element{dynamic: false} = el, _ctx), do: el

  defp evaluate_element(%Element{} = el, ctx) do
    comp = Library.get_component(ctx.lib, el.type_name)
    bindable = if comp, do: comp.bindable, else: MapSet.new()
    outer = Process.get(@prop_key)
    props = Map.new(el.props, fn {key, v} -> {key, evaluate_prop(el, key, v, bindable, ctx)} end)
    restore(@prop_key, outer)
    %{el | props: props, dynamic: false}
  end

  # A prop whose evaluation fails becomes null and reports a runtime-error (section 8.2).
  defp evaluate_prop(el, key, value, bindable, ctx) do
    Process.put(@prop_key, {el.type_name, el.statement_id, key})

    case guarded(fn -> eval_prop(value, MapSet.member?(bindable, key), ctx) end) do
      {:ok, v} ->
        v

      {:error, e} ->
        report("Evaluating prop \"#{key}\" on #{el.type_name} failed: #{describe(e)}")
        nil
    end
  end

  defp describe({:openui_budget, msg}), do: msg
  defp describe(%{__exception__: true} = e), do: Exception.message(e)

  defp eval_prop(nil, _b, _ctx), do: nil
  defp eval_prop({:state, name}, true, _ctx), do: %Binding{target: name}
  defp eval_prop({:assign, target, expr}, true, _ctx), do: %Binding{target: target, expr: expr}

  defp eval_prop(ast, bindable?, ctx) when is_tuple(ast) do
    case eval(ast, ctx) do
      %Binding{target: t} when not bindable? -> ctx.get_state.(t)
      v -> finish(v, ctx)
    end
  end

  defp eval_prop(list, b, ctx) when is_list(list), do: Enum.map(list, &eval_prop(&1, b, ctx))
  defp eval_prop(%Element{} = el, _b, ctx), do: evaluate_element(el, ctx)
  defp eval_prop(%ActionPlan{} = plan, _b, _ctx), do: plan
  defp eval_prop(%Binding{} = b, _b, _ctx), do: b

  defp eval_prop(map, b, ctx) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, eval_prop(v, b, ctx)} end)

  defp eval_prop(v, _b, _ctx), do: v

  # Elements produced by expressions still hold `$variable` props; evaluate them in place.
  defp finish(%Element{} = el, ctx), do: evaluate_element(el, ctx)
  defp finish(list, ctx) when is_list(list), do: Enum.map(list, &finish(&1, ctx))

  defp finish(map, ctx) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, finish(v, ctx)} end)

  defp finish(v, _ctx), do: v

  # ── Expressions ──────────────────────────────────────────────────────────

  @doc """
  Evaluates one AST node. Called on its own (outside `evaluate_root/2` and `evaluate_value/2`),
  it runs under the same step budget and gives null when the budget runs out, so a state default
  or an action value cannot hang the caller.
  """
  def eval(node, ctx) do
    case Process.get(@steps_key) do
      nil ->
        Process.put(@steps_key, 0)

        try do
          do_eval(node, ctx)
        catch
          :throw, {:openui_budget, _} -> nil
        after
          Process.delete(@steps_key)
        end

      _ ->
        tick()
        do_eval(node, ctx)
    end
  end

  defp tick do
    case Process.get(@steps_key) do
      n when n >= @max_steps ->
        throw({:openui_budget, "evaluation exceeded #{@max_steps} steps"})

      n ->
        Process.put(@steps_key, n + 1)
    end
  end

  defp do_eval({:str, v}, _ctx), do: v
  defp do_eval({:num, v}, _ctx), do: v
  defp do_eval({:bool, v}, _ctx), do: v
  defp do_eval({:null}, _ctx), do: nil
  defp do_eval({:ph, _}, _ctx), do: nil
  defp do_eval({:const, v}, _ctx), do: v

  defp do_eval({:state, name}, ctx),
    do: Map.get_lazy(ctx.scope, name, fn -> ctx.get_state.(name) end)

  defp do_eval({:ref, name}, ctx) do
    case Map.fetch(ctx.scope, name) do
      {:ok, v} -> v
      :error -> ctx.resolve_ref.(name)
    end
  end

  defp do_eval({:rref, name, _type}, ctx), do: ctx.resolve_ref.(name)

  # Unresolved references and invalid components inside arrays are left out (sections 2.3, 8.4).
  defp do_eval({:arr, els}, ctx) do
    for el <- els, not omitted?(el, ctx), do: eval(el, ctx)
  end

  defp do_eval({:obj, entries}, ctx), do: Map.new(entries, fn {k, v} -> {k, eval(v, ctx)} end)

  defp do_eval({:bin, "&&", l, r}, ctx) do
    left = eval(l, ctx)
    if JS.truthy?(left), do: eval(r, ctx), else: left
  end

  defp do_eval({:bin, "||", l, r}, ctx) do
    left = eval(l, ctx)
    if JS.truthy?(left), do: left, else: eval(r, ctx)
  end

  defp do_eval({:bin, op, l, r}, ctx), do: binary(op, eval(l, ctx), eval(r, ctx))

  defp do_eval({:unary, "!", x}, ctx), do: not JS.truthy?(eval(x, ctx))
  defp do_eval({:unary, "-", x}, ctx), do: x |> eval(ctx) |> JS.to_number() |> JS.negate()
  defp do_eval({:unary, _, _}, _ctx), do: nil

  defp do_eval({:ternary, c, t, e}, ctx) do
    if JS.truthy?(eval(c, ctx)), do: eval(t, ctx), else: eval(e, ctx)
  end

  defp do_eval({:member, obj, field}, ctx), do: member(eval(obj, ctx), field)

  defp do_eval({:index, obj, idx}, ctx), do: index(eval(obj, ctx), eval(idx, ctx))

  defp do_eval({:assign, target, expr}, _ctx), do: %Binding{target: target, expr: expr}

  defp do_eval({:call, _, _, _, _} = node, ctx), do: call(node, ctx)

  defp do_eval(_other, _ctx), do: nil

  defp omitted?({:ph, _}, _ctx), do: true

  defp omitted?({:call, name, _, false, nil}, ctx) do
    Library.get_call(ctx.lib, name) == nil and name not in ["Query", "Mutation"] and
      not Library.component?(ctx.lib, name)
  end

  defp omitted?(_, _ctx), do: false

  defp binary("+", a, b) when is_binary(a) or is_binary(b), do: concat_part(a) <> concat_part(b)
  defp binary("+", a, b), do: JS.add(JS.to_number(a), JS.to_number(b))
  defp binary("-", a, b), do: JS.sub(JS.to_number(a), JS.to_number(b))
  defp binary("*", a, b), do: JS.mul(JS.to_number(a), JS.to_number(b))
  defp binary("/", a, b), do: JS.divide(JS.to_number(a), JS.to_number(b))
  defp binary("%", a, b), do: JS.rem(JS.to_number(a), JS.to_number(b))
  defp binary("==", a, b), do: JS.loose_equal?(a, b)
  defp binary("!=", a, b), do: not JS.loose_equal?(a, b)
  defp binary(">", a, b), do: JS.less_than(JS.to_number(b), JS.to_number(a))
  defp binary("<", a, b), do: JS.less_than(JS.to_number(a), JS.to_number(b))
  defp binary(">=", a, b), do: not_less(JS.to_number(a), JS.to_number(b))
  defp binary("<=", a, b), do: not_less(JS.to_number(b), JS.to_number(a))
  defp binary(_, _a, _b), do: nil

  defp not_less(a, b), do: JS.less_than(b, a) or JS.num_equal(a, b)

  defp concat_part(nil), do: ""
  defp concat_part(v), do: JS.to_string_value(v)

  # a.b reads a field; on an array it plucks, `.length` counts; on null it is null.
  defp member(nil, _field), do: nil
  defp member(list, "length") when is_list(list), do: length(list)

  defp member(list, field) when is_list(list), do: Enum.map(list, &field_of(&1, field))
  defp member(other, field), do: field_of(other, field)

  # JavaScript property access on one value: object fields, array indexes and `length`.
  defp field_of(map, field) when is_map(map) and not is_struct(map), do: Map.get(map, field)
  defp field_of(list, "length") when is_list(list), do: length(list)

  defp field_of(list, field) when is_list(list) do
    case Integer.parse(field) do
      {i, ""} when i >= 0 -> Enum.at(list, i)
      _ -> nil
    end
  end

  defp field_of(str, "length") when is_binary(str), do: Builtins.utf16_length(str)
  defp field_of(_other, _field), do: nil

  defp index(nil, _), do: nil
  defp index(_, nil), do: nil

  defp index(list, i) when is_list(list) do
    case JS.to_number(i) do
      n when is_integer(n) and n >= 0 -> Enum.at(list, n)
      _ -> nil
    end
  end

  defp index(map, key) when is_map(map) and not is_struct(map),
    do: Map.get(map, JS.to_string_value(key))

  defp index(str, i) when is_binary(str) do
    case JS.to_number(i) do
      n when is_integer(n) and n >= 0 -> String.at(str, n)
      _ -> nil
    end
  end

  defp index(_, _), do: nil

  # ── Calls ────────────────────────────────────────────────────────────────

  defp call({:call, name, args, _fn?, mapped} = node, ctx) do
    cond do
      name == "Each" ->
        each(args, ctx)

      Builtins.function?(name) ->
        Builtins.call(name, eval_named(mapped || name_args(args, Builtins.params(name)), ctx))

      Builtins.step?(name) ->
        action_call(name, args, mapped, ctx)

      fun = ctx.lib && ctx.lib.functions[name] ->
        call_function(fun, node, ctx)

      act = ctx.lib && ctx.lib.actions[name] ->
        custom_action(act, node, ctx)

      mapped != nil ->
        props =
          Map.new(mapped, fn
            {k, {:state, _} = v} -> {k, v}
            {k, v} -> {k, eval(v, ctx)}
          end)

        %Element{type_name: name, props: props, dynamic: true}

      true ->
        nil
    end
  end

  defp name_args(args, names), do: names |> Enum.zip(args)

  defp eval_named(pairs, ctx), do: Map.new(pairs, fn {k, v} -> {k, eval(v, ctx)} end)

  # A library function's or action's arguments. An explicit null for an optional param is
  # left out, so its default applies.
  defp call_args({:call, _, args, _, mapped}, params, ctx) do
    pairs = mapped || Materializer.name_args(args, params)
    required = for p <- params, p.required, do: p.name

    pairs
    |> eval_named(ctx)
    |> Enum.reject(fn {k, v} -> is_nil(v) and k not in required end)
    |> Map.new()
    |> fill_defaults(params)
  end

  defp fill_defaults(args, params) do
    Enum.reduce(params, args, fn
      %{name: n, default: {:ok, d}}, acc ->
        if is_nil(Map.get(acc, n)), do: Map.put(acc, n, d), else: acc

      _, acc ->
        acc
    end)
  end

  defp misses_required?(args, params) do
    Enum.any?(params, &(&1.required and is_nil(Map.get(args, &1.name)) and &1.default == :none))
  end

  defp call_function(fun, node, ctx) do
    raw = call_args(node, fun.params, ctx)

    with false <- misses_required?(raw, fun.params),
         args when args != :invalid <- check_value(raw, fun.params_schema, fun.name, "", false),
         {:ok, result} <- run_impl(fun, args) do
      check_returns(result, fun)
    else
      _ -> nil
    end
  end

  # A return value that does not match `returns` reports a runtime-error and gives null.
  defp check_returns(result, %{returns: nil}), do: result

  defp check_returns(result, fun) do
    case check_value(result, fun.returns, fun.name, "/returns", false) do
      :invalid -> nil
      v -> v
    end
  end

  defp run_impl(%{impl: nil, name: name}, _args) do
    report("@#{name} has no implementation in this client")
    :error
  end

  # A function that raises, throws or exits must not take the host down (language.md, 3.6).
  # Its result is normalized like any host value, so a tuple or pid cannot reach the tree.
  defp run_impl(%{impl: impl, name: name}, args) do
    {:ok, Values.from_host(impl.(args))}
  rescue
    e ->
      report("@#{name} threw: #{Exception.message(e)}")
      :error
  catch
    kind, reason ->
      report("@#{name} threw: #{Exception.format_banner(kind, reason)}")
      :error
  end

  defp custom_action(act, node, ctx) do
    args = call_args(node, act.params, ctx)

    if misses_required?(args, act.params) do
      %ActionPlan{}
    else
      case check_value(args, act.params_schema, act.name, "", true) do
        :invalid ->
          %ActionPlan{}

        params ->
          %ActionPlan{steps: [{:custom, act.name, params, Enum.map(act.params, & &1.name)}]}
      end
    end
  end

  # strict: any reported error makes the value invalid instead of falling back to a default.
  defp check_value(value, schema, name, path, strict?) do
    vctx = %{errors: [], partial: false, lib: nil, current: nil}
    {checked, vctx} = Validation.check(value, schema, name, path, vctx)
    vctx.errors |> Enum.reverse() |> Enum.each(&report("@#{name}: #{&1.message}"))
    if strict? and vctx.errors != [], do: :invalid, else: checked
  end

  # ── Actions ──────────────────────────────────────────────────────────────

  defp action_call("Action", args, _mapped, ctx) do
    list =
      case args do
        [first | _] -> eval(first, ctx)
        [] -> []
      end

    steps =
      if is_list(list),
        do:
          Enum.flat_map(list, fn
            %ActionPlan{steps: s} -> s
            _ -> []
          end),
        else: []

    %ActionPlan{steps: steps}
  end

  defp action_call("ToAssistant", args, mapped, ctx) do
    a = eval_named(mapped || name_args(args, Builtins.params("ToAssistant")), ctx)
    context = if is_nil(a["context"]), do: :none, else: a["context"]
    %ActionPlan{steps: [{:continue_conversation, concat_part(a["message"]), context}]}
  end

  defp action_call("OpenUrl", args, mapped, ctx) do
    a = eval_named(mapped || name_args(args, Builtins.params("OpenUrl")), ctx)
    %ActionPlan{steps: [{:open_url, concat_part(a["url"])}]}
  end

  defp action_call("Run", [{:rref, id, type} | _], _mapped, _ctx),
    do: %ActionPlan{steps: [{:run, id, type}]}

  defp action_call("Run", _args, _mapped, _ctx), do: %ActionPlan{}

  defp action_call("Set", [{:state, target}, value | _], _mapped, _ctx),
    do: %ActionPlan{steps: [{:set, target, value}]}

  defp action_call("Set", _args, _mapped, _ctx), do: %ActionPlan{}

  defp action_call("Reset", args, _mapped, _ctx) do
    case for({:state, n} <- args, do: n) do
      [] -> %ActionPlan{}
      targets -> %ActionPlan{steps: [{:reset, targets}]}
    end
  end

  # ── @Each ────────────────────────────────────────────────────────────────

  # The element is put into the template before any deferred evaluation, so an action in the
  # template captures its own element (section 3.5).
  defp each([array_node, var_node, template | _], ctx) do
    with list when is_list(list) <- eval(array_node, ctx),
         var when is_binary(var) <- Materializer.loop_var(var_node) do
      list =
        if length(list) > @max_each do
          report("@Each over #{length(list)} elements was cut to #{@max_each}")
          Enum.take(list, @max_each)
        else
          list
        end

      Enum.map(list, fn item ->
        child = %{ctx | scope: Map.put(ctx.scope, var, item)}
        template |> substitute(var, item) |> eval(child)
      end)
    else
      _ -> []
    end
  end

  defp each(_args, _ctx), do: []

  # Replaces references to the loop variable with the element. A nested @Each that binds the same
  # name shadows it, so its template is left alone.
  defp substitute({:ref, var}, var, value), do: {:const, value}

  defp substitute({:call, "Each", [arr, var_node | rest], fn?, mapped}, var, value) do
    if Materializer.loop_var(var_node) == var,
      do: {:call, "Each", [substitute(arr, var, value), var_node | rest], fn?, mapped},
      else:
        {:call, "Each", Enum.map([arr, var_node | rest], &substitute(&1, var, value)), fn?,
         mapped}
  end

  # `mapped` holds the same nodes as `args` by position (or a literal default); reuse the
  # substituted argument instead of walking it again, which would double per nesting level.
  defp substitute({:call, name, args, fn?, mapped}, var, value) do
    new_args = Enum.map(args, &substitute(&1, var, value))

    mapped =
      mapped &&
        mapped
        |> Enum.with_index()
        |> Enum.map(fn {{k, v}, i} ->
          case Enum.at(args, i) do
            ^v -> {k, Enum.at(new_args, i)}
            _ -> {k, substitute(v, var, value)}
          end
        end)

    {:call, name, new_args, fn?, mapped}
  end

  defp substitute({:arr, els}, var, value), do: {:arr, Enum.map(els, &substitute(&1, var, value))}

  defp substitute({:obj, entries}, var, value),
    do: {:obj, Enum.map(entries, fn {k, v} -> {k, substitute(v, var, value)} end)}

  defp substitute({:bin, op, l, r}, var, value),
    do: {:bin, op, substitute(l, var, value), substitute(r, var, value)}

  defp substitute({:unary, op, x}, var, value), do: {:unary, op, substitute(x, var, value)}

  defp substitute({:ternary, c, t, e}, var, value),
    do:
      {:ternary, substitute(c, var, value), substitute(t, var, value), substitute(e, var, value)}

  defp substitute({:member, o, f}, var, value), do: {:member, substitute(o, var, value), f}

  defp substitute({:index, o, i}, var, value),
    do: {:index, substitute(o, var, value), substitute(i, var, value)}

  defp substitute({:assign, t, v}, var, value), do: {:assign, t, substitute(v, var, value)}
  defp substitute(node, _var, _value), do: node

  # ── Errors ───────────────────────────────────────────────────────────────

  defp report(message) do
    case Process.get(@errors_key) do
      nil ->
        :ok

      errors ->
        {component, statement_id, key} = Process.get(@prop_key) || {nil, nil, nil}

        error = %Error{
          source: :runtime,
          code: "runtime-error",
          component: component,
          statement_id: statement_id,
          message: message,
          hint: key && "Check the expression used for prop \"#{key}\""
        }

        Process.put(@errors_key, [error | errors])
    end
  end

  defp push_error(error) do
    case Process.get(@errors_key) do
      nil -> :ok
      errors -> Process.put(@errors_key, [error | errors])
    end
  end
end
