defmodule LiveRender.OpenUI.Materializer do
  @moduledoc """
  Schema-aware lowering of statement ASTs (language.md, sections 2, 8.2 and 8.4).

  One traversal resolves references (inlining the referenced statement, detecting cycles and
  turning query/mutation references into `{:rref, name, type}`), maps component arguments to named
  props, validates them, applies defaults, reports errors, and keeps anything that depends on state
  or queries as AST for the evaluator.

  `value/2` is used in value positions: it returns plain values, `%Element{}` structs, or AST
  tuples for runtime expressions. `expr/3` is used inside computed expressions: it always returns
  AST.

  Every function threads a `Ctx` and returns `{result, ctx}`.

  A statement referenced from several places is inlined at each (language.md, section 2.3), so a
  chain of statements that each reference the next twice grows exponentially. `Ctx.budget` caps
  the number of inlinings per parse; past it a reference is unresolved, so no program can hang
  the parser.
  """

  alias LiveRender.OpenUI.{Element, Library, Signature, Validation}

  defmodule Ctx do
    @moduledoc false
    defstruct syms: %{},
              lib: nil,
              errors: [],
              unres: [],
              visited: MapSet.new(),
              partial: false,
              current: nil,
              unreached: MapSet.new(),
              budget: 50_000
  end

  @reserved ["Query", "Mutation"]

  # ── References ───────────────────────────────────────────────────────────

  defp resolve_ref(name, ctx, mode) do
    if resolvable?(name, ctx) do
      ctx = %{ctx | unreached: MapSet.delete(ctx.unreached, name), budget: ctx.budget - 1}
      inline(Map.fetch!(ctx.syms, name), name, ctx, mode)
    else
      {placeholder(name, mode), %{ctx | unres: [name | ctx.unres]}}
    end
  end

  # A missing statement, one that closes a cycle, or one past the inlining budget is unresolved.
  defp resolvable?(name, ctx),
    do: ctx.budget > 0 and Map.has_key?(ctx.syms, name) and not MapSet.member?(ctx.visited, name)

  defp placeholder(name, :expr), do: {:ph, name}
  defp placeholder(_name, :value), do: nil

  # Query and Mutation statements resolve to their results at runtime.
  defp inline({:call, "Query", _, _, _}, name, ctx, _mode), do: {{:rref, name, :query}, ctx}
  defp inline({:call, "Mutation", _, _, _}, name, ctx, _mode), do: {{:rref, name, :mutation}, ctx}

  defp inline(target, name, ctx, mode) do
    {current, visited} = {ctx.current, ctx.visited}
    ctx = %{ctx | visited: MapSet.put(visited, name), current: name}
    {result, ctx} = if mode == :value, do: value(target, ctx), else: expr(target, ctx)
    {tag(result, name, mode), %{ctx | current: current, visited: visited}}
  end

  defp tag(%Element{} = el, name, :value), do: %{el | statement_id: name}
  defp tag(result, _name, _mode), do: result

  # ── Value positions ──────────────────────────────────────────────────────

  @doc "Materializes a node in a value position."
  def value({:ref, name}, ctx), do: resolve_ref(name, ctx, :value)
  def value({:str, v}, ctx), do: {v, ctx}
  def value({:num, v}, ctx), do: {v, ctx}
  def value({:bool, v}, ctx), do: {v, ctx}
  def value({:null}, ctx), do: {nil, ctx}
  def value({:ph, _}, ctx), do: {nil, ctx}

  def value({:arr, els}, ctx) do
    {items, ctx} = Enum.reduce(els, {[], ctx}, &array_item/2)
    {Enum.reverse(items), ctx}
  end

  def value({:obj, entries}, ctx) do
    Enum.reduce(entries, {%{}, ctx}, fn {k, node}, {map, ctx} ->
      {v, ctx} = value(node, ctx)
      {Map.put(map, k, v), ctx}
    end)
  end

  def value({:call, name, args, fn?, _} = node, ctx) do
    cond do
      fn? and not runtime_call?(name, ctx) ->
        {nil, Validation.issue(ctx, name, "", :unknown_function)}

      name in @reserved ->
        {nil, Validation.issue(ctx, name, "", :inline_reserved)}

      runtime_call?(name, ctx) ->
        case lazy(node, ctx, MapSet.new()) do
          {:ok, result} -> result
          :no -> call(node, ctx, &expr(&1, &2, MapSet.new()))
        end

      comp = Library.get_component(ctx.lib, name) ->
        component(comp, name, args, ctx)

      true ->
        {nil,
         Validation.issue(ctx, name, "", {:unknown_component, Library.component_names(ctx.lib)})}
    end
  end

  def value(node, ctx), do: expr(node, ctx, MapSet.new())

  # Unresolved references, dropped components and incomplete calls leave no hole.
  defp array_item({:ph, _}, acc), do: acc

  defp array_item(el, {items, ctx}) do
    {v, ctx} = value(el, ctx)
    if is_nil(v) and elem(el, 0) in [:call, :ref], do: {items, ctx}, else: {[v | items], ctx}
  end

  defp component(comp, name, args, ctx) do
    {props, drop?, ctx} =
      comp.params
      |> Enum.zip(args)
      |> Enum.reduce({%{}, false, ctx}, &component_prop(&1, &2, name))

    ctx = excess_args(ctx, name, length(comp.params), length(args))
    {props, missing} = fill_required(comp.params, props)

    cond do
      missing != [] -> {nil, report_missing(ctx, name, comp.params, props, missing)}
      drop? -> {nil, ctx}
      true -> {element(name, props, ctx), ctx}
    end
  end

  defp element(name, props, ctx),
    do: %Element{type_name: name, props: props, partial: ctx.partial, dynamic: dynamic?(props)}

  # An invalid required prop with no default drops the component; its error is already reported.
  defp component_prop({param, arg}, {props, drop?, ctx}, name) do
    {v, ctx} = value(arg, ctx)
    {next, ctx} = Validation.check(v, param.check || param.schema, name, "/" <> param.name, ctx)

    case resolve_edge(next, param) do
      :invalid -> {Map.put(props, param.name, v), true, ctx}
      :omit -> {props, drop?, ctx}
      v2 -> {Map.put(props, param.name, v2), drop?, ctx}
    end
  end

  defp resolve_edge(:invalid, param),
    do: Validation.resolve_invalid(param.required, param.default)

  defp resolve_edge(value, _param), do: value

  defp excess_args(ctx, name, declared, got) when got > declared,
    do: Validation.issue(ctx, name, "", {:excess_args, declared, got})

  defp excess_args(ctx, _name, _declared, _got), do: ctx

  # A missing or null required prop takes its schema default before the component is dropped.
  defp fill_required(params, props) do
    params
    |> Enum.filter(&(&1.required and is_nil(Map.get(props, &1.name))))
    |> Enum.reduce({props, []}, fn
      %{default: {:ok, d}} = p, {props, missing} -> {Map.put(props, p.name, d), missing}
      p, {props, missing} -> {props, missing ++ [p]}
    end)
  end

  defp report_missing(ctx, name, params, props, missing) do
    sig = Signature.typed(name, params)

    Enum.reduce(missing, ctx, fn p, ctx ->
      code = if Map.has_key?(props, p.name), do: :null_required, else: :missing_required
      Validation.issue(ctx, name, "/" <> p.name, {code, sig})
    end)
  end

  @doc "True when a value still holds AST nodes that need evaluation."
  def dynamic?(v) when is_tuple(v), do: true
  def dynamic?(v) when is_list(v), do: Enum.any?(v, &dynamic?/1)
  def dynamic?(%Element{props: props}), do: Enum.any?(props, fn {_, p} -> dynamic?(p) end)

  def dynamic?(v) when is_map(v) and not is_struct(v),
    do: Enum.any?(v, fn {_, p} -> dynamic?(p) end)

  def dynamic?(_), do: false

  # ── Computed expressions ─────────────────────────────────────────────────

  @doc "Materializes a node inside a computed expression. Always returns AST."
  def expr(node, ctx, scoped \\ MapSet.new())

  def expr({:ref, name} = node, ctx, scoped) do
    if MapSet.member?(scoped, name), do: {node, ctx}, else: resolve_ref(name, ctx, :expr)
  end

  def expr({:call, name, _args, fn?, _} = node, ctx, scoped) do
    if fn? and not runtime_call?(name, ctx) do
      {{:null}, Validation.issue(ctx, name, "", :unknown_function)}
    else
      case lazy(node, ctx, scoped) do
        {:ok, result} -> result
        :no -> expr_call(node, ctx, scoped)
      end
    end
  end

  def expr({:arr, els}, ctx, scoped) do
    {els, ctx} = map_nodes(els, ctx, &expr(&1, &2, scoped))
    {{:arr, els}, ctx}
  end

  def expr({:obj, entries}, ctx, scoped) do
    {entries, ctx} =
      Enum.reduce(entries, {[], ctx}, fn {k, v}, {acc, ctx} ->
        {v, ctx} = expr(v, ctx, scoped)
        {[{k, v} | acc], ctx}
      end)

    {{:obj, Enum.reverse(entries)}, ctx}
  end

  def expr({:bin, op, l, r}, ctx, scoped) do
    {l, ctx} = expr(l, ctx, scoped)
    {r, ctx} = expr(r, ctx, scoped)
    {{:bin, op, l, r}, ctx}
  end

  def expr({:unary, op, x}, ctx, scoped) do
    {x, ctx} = expr(x, ctx, scoped)
    {{:unary, op, x}, ctx}
  end

  def expr({:ternary, c, t, e}, ctx, scoped) do
    {c, ctx} = expr(c, ctx, scoped)
    {t, ctx} = expr(t, ctx, scoped)
    {e, ctx} = expr(e, ctx, scoped)
    {{:ternary, c, t, e}, ctx}
  end

  def expr({:member, obj, field}, ctx, scoped) do
    {obj, ctx} = expr(obj, ctx, scoped)
    {{:member, obj, field}, ctx}
  end

  def expr({:index, obj, idx}, ctx, scoped) do
    {obj, ctx} = expr(obj, ctx, scoped)
    {idx, ctx} = expr(idx, ctx, scoped)
    {{:index, obj, idx}, ctx}
  end

  def expr({:assign, target, v}, ctx, scoped) do
    {v, ctx} = expr(v, ctx, scoped)
    {{:assign, target, v}, ctx}
  end

  # Literals, placeholders, state and runtime references pass through.
  def expr(node, ctx, _scoped), do: {node, ctx}

  defp map_nodes(nodes, ctx, fun) do
    {out, ctx} =
      Enum.reduce(nodes, {[], ctx}, fn n, {acc, ctx} ->
        {v, ctx} = fun.(n, ctx)
        {[v | acc], ctx}
      end)

    {Enum.reverse(out), ctx}
  end

  defp expr_call({:call, name, args, fn?, _} = node, ctx, scoped) do
    if runtime_call?(name, ctx) do
      call(node, ctx, &expr(&1, &2, scoped))
    else
      {args, ctx} = map_nodes(args, ctx, &expr(&1, &2, scoped))
      expr_component(Library.get_component(ctx.lib, name), name, args, fn?, ctx)
    end
  end

  # A component inside an expression is mapped but not validated. An unknown one stays in the tree
  # for its error to point at, and renders nothing.
  defp expr_component(nil, name, args, fn?, ctx) do
    ctx = Validation.issue(ctx, name, "", {:unknown_component, Library.component_names(ctx.lib)})
    {{:call, name, args, fn?, nil}, ctx}
  end

  defp expr_component(comp, name, args, fn?, ctx),
    do: {{:call, name, args, fn?, name_args(args, comp.params)}, ctx}

  # ── Calls ────────────────────────────────────────────────────────────────

  defp runtime_call?(name, ctx), do: Library.get_call(ctx.lib, name) != nil or name in @reserved

  # @Each(array, varName, template): the loop variable shadows statements inside the template.
  defp lazy({:call, name, args, fn?, _}, ctx, scoped) do
    with %{kind: :function, lazy: true} <- Library.get_call(ctx.lib, name),
         [_, var_node, _ | _] <- args,
         var when is_binary(var) <- loop_var(var_node) do
      inner = MapSet.put(scoped, var)
      {args, ctx} = args |> Enum.with_index() |> map_nodes(ctx, &lazy_arg(&1, &2, inner))
      {:ok, {{:call, name, args, fn?, nil}, ctx}}
    else
      _ -> :no
    end
  end

  # The loop variable argument itself is kept as written.
  defp lazy_arg({arg, 1}, ctx, _inner), do: {arg, ctx}
  defp lazy_arg({arg, _}, ctx, inner), do: expr(arg, ctx, inner)

  @doc "The loop variable name of an `@Each` call's second argument (a name or a string), or nil."
  def loop_var({:ref, n}), do: n
  def loop_var({:str, v}), do: v
  def loop_var(_), do: nil

  defp call({:call, name, args, fn?, _}, ctx, arg_fun) do
    {args, ctx} = map_nodes(args, ctx, arg_fun)

    case Library.get_call(ctx.lib, name) do
      nil ->
        {{:call, name, args, fn?, nil}, ctx}

      %{lazy: true} ->
        {{:call, name, args, fn?, nil}, ctx}

      %{builtin: true, params: params} ->
        {{:call, name, args, fn?, name_args(args, params)}, ctx}

      def ->
        case map_call_args(name, args, def, ctx) do
          {nil, ctx} when def.kind == :action ->
            {{:call, "Action", [{:arr, []}], false, nil}, ctx}

          {nil, ctx} ->
            {{:null}, ctx}

          {mapped, ctx} ->
            {{:call, name, args, fn?, mapped}, ctx}
        end
    end
  end

  @doc "Pairs arguments with parameter names by position. Extra arguments are dropped."
  def name_args(args, params) do
    params |> Enum.zip(args) |> Enum.map(fn {p, a} -> {p.name, a} end)
  end

  # Literal arguments of library functions and actions are checked when parsing (section 3.6).
  # Returns {mapped | nil, ctx}; nil means the call is invalid.
  defp map_call_args(name, args, def, ctx) do
    params = def.params
    ctx = excess_args(ctx, name, length(params), length(args))
    errors_before = length(ctx.errors)
    check = &check_call_arg(&1, &2, name, params)

    {mapped, invalid, ctx} = Enum.reduce(params, {name_args(args, params), false, ctx}, check)

    # An action never runs with a value the model did not write.
    invalid = invalid or (def.kind == :action and length(ctx.errors) > errors_before)
    {if(invalid, do: nil, else: mapped), ctx}
  end

  defp check_call_arg(p, {mapped, _invalid, _ctx} = acc, name, params) do
    arg = List.keyfind(mapped, p.name, 0)

    case arg_literal(arg) do
      :error -> acc
      {:ok, nil} -> check_null_arg(p, arg, acc, name, params)
      {:ok, v} -> check_literal_arg(p, v, acc, name)
    end
  end

  defp arg_literal(nil), do: {:ok, nil}
  defp arg_literal({_, node}), do: literal_value(node)

  # An absent or null required argument with no default makes the call invalid.
  defp check_null_arg(%{required: true, default: :none} = p, arg, {mapped, _, ctx}, name, params) do
    code = if arg, do: :null_required, else: :missing_required

    {mapped, true,
     Validation.issue(ctx, name, "/" <> p.name, {code, Signature.typed(name, params)})}
  end

  defp check_null_arg(_p, _arg, acc, _name, _params), do: acc

  defp check_literal_arg(p, v, {mapped, invalid, ctx}, name) do
    {next, ctx} = Validation.check(v, p.check || p.schema, name, "/" <> p.name, ctx)

    case resolve_edge(next, p) do
      :invalid -> {mapped, true, ctx}
      :omit -> {List.keydelete(mapped, p.name, 0), invalid, ctx}
      ^v -> {mapped, invalid, ctx}
      other -> {List.keystore(mapped, p.name, 0, {p.name, to_literal(other)}), invalid, ctx}
    end
  end

  @doc "The plain value of a literal AST node, or `:error` when it is not a literal."
  def literal_value({:str, v}), do: {:ok, v}
  def literal_value({:num, v}), do: {:ok, v}
  def literal_value({:bool, v}), do: {:ok, v}
  def literal_value({:null}), do: {:ok, nil}

  def literal_value({:arr, els}) do
    Enum.reduce_while(els, {:ok, []}, fn el, {:ok, acc} ->
      case literal_value(el) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      :error -> :error
    end
  end

  def literal_value({:obj, entries}) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {k, el}, {:ok, acc} ->
      case literal_value(el) do
        {:ok, v} -> {:cont, {:ok, Map.put(acc, k, v)}}
        :error -> {:halt, :error}
      end
    end)
  end

  def literal_value(_), do: :error

  @doc "A literal AST node for a plain value."
  def to_literal(nil), do: {:null}
  def to_literal(v) when is_binary(v), do: {:str, v}
  def to_literal(v) when is_boolean(v), do: {:bool, v}
  def to_literal(v) when is_number(v) or v in [:infinity, :neg_infinity, :nan], do: {:num, v}
  def to_literal(v) when is_list(v), do: {:arr, Enum.map(v, &to_literal/1)}

  def to_literal(v) when is_map(v) and not is_struct(v),
    do: {:obj, Enum.map(v, fn {k, val} -> {k, to_literal(val)} end)}

  def to_literal(_), do: {:null}

  # ── Walking ──────────────────────────────────────────────────────────────

  @doc "Calls `fun` on every AST node under `node`, depth first. Returns the accumulator."
  def walk(node, acc, fun) do
    acc = fun.(node, acc)

    case node do
      # `mapped` pairs the same argument nodes with names (plus literal defaults); walking it
      # too would visit nested calls twice per level, 2^depth times in all.
      {:call, _, args, _, _mapped} ->
        Enum.reduce(args, acc, &walk(&1, &2, fun))

      {:arr, els} ->
        Enum.reduce(els, acc, &walk(&1, &2, fun))

      {:obj, entries} ->
        Enum.reduce(entries, acc, fn {_, n}, a -> walk(n, a, fun) end)

      {:bin, _, l, r} ->
        walk(r, walk(l, acc, fun), fun)

      {:unary, _, x} ->
        walk(x, acc, fun)

      {:ternary, c, t, e} ->
        walk(e, walk(t, walk(c, acc, fun), fun), fun)

      {:member, o, _} ->
        walk(o, acc, fun)

      {:index, o, i} ->
        walk(i, walk(o, acc, fun), fun)

      {:assign, _, v} ->
        walk(v, acc, fun)

      _ ->
        acc
    end
  end

  @doc "The `$variable` names referenced anywhere under `node`, in first-seen order."
  def state_refs(node) do
    node
    |> walk([], fn
      {:state, n}, acc -> if n in acc, do: acc, else: [n | acc]
      _, acc -> acc
    end)
    |> Enum.reverse()
  end

  @doc "True for a call to a library component (not a function, built-in, Query or Mutation)."
  def component_call?({:call, name, _, false, _}),
    do: not LiveRender.OpenUI.Builtins.reserved?(name)

  def component_call?(_), do: false
end
