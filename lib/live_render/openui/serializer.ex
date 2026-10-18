defmodule LiveRender.OpenUI.Serializer do
  @moduledoc """
  Serializes a rendered tree back to OpenUI Lang (language.md, section 9.2).

    * The entry statement comes first; every other named component becomes its own statement,
      children before parents.
    * Props are written by position in schema order; `null` holds an unfilled required position
      and trailing nulls for optional props are trimmed.
    * State declarations given in `:state` come after the component statements.
    * Parentheses are added where parsing back would change the grouping.

  The output parses back to an equal tree, up to the recovery rules of section 8.
  """

  alias LiveRender.OpenUI.{ActionPlan, Binding, Builtins, Element, JS, Library}

  @precedence %{
    "||" => 2,
    "&&" => 3,
    "==" => 4,
    "!=" => 4,
    ">" => 5,
    "<" => 5,
    ">=" => 5,
    "<=" => 5,
    "+" => 6,
    "-" => 6,
    "*" => 7,
    "/" => 7,
    "%" => 7
  }

  @doc """
  Serializes `tree`. Options: `:state` — a map of `$name => default` to append (null defaults
  are left out, since undeclared names default to null).
  """
  @spec to_source(Element.t(), Library.t(), keyword()) :: String.t()
  def to_source(%Element{} = tree, %Library{} = lib, opts \\ []) do
    {root_expr, collected} = element_expr(tree, lib, [])
    root_id = tree.statement_id || "root"

    children =
      collected
      |> Enum.reverse()
      |> Enum.reject(fn {id, _} -> id == root_id end)
      |> Enum.map(fn {id, text} -> "#{id} = #{text}" end)

    state =
      opts
      |> Keyword.get(:state, %{})
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> "#{k} = #{elem(value(v, lib, []), 0)}" end)

    Enum.join(["#{root_id} = #{root_expr}" | children] ++ state, "\n")
  end

  defp element_expr(%Element{type_name: type, props: props}, lib, acc) do
    case Library.get_component(lib, type) do
      nil ->
        {args, acc} = map_values(Map.values(props), lib, acc)
        {"#{type}(#{Enum.join(args, ", ")})", acc}

      comp ->
        {args, acc} = map_values(Enum.map(comp.params, &Map.get(props, &1.name)), lib, acc)
        args = trim_trailing(args, comp.params)
        {"#{type}(#{Enum.join(args, ", ")})", acc}
    end
  end

  defp trim_trailing(args, params) do
    pairs = args |> Enum.zip(params) |> Enum.reverse()

    pairs
    |> Enum.drop_while(fn {arg, p} -> arg == "null" and not p.required end)
    |> Enum.reverse()
    |> Enum.map(&elem(&1, 0))
  end

  defp map_values(values, lib, acc) do
    {out, acc} =
      Enum.reduce(values, {[], acc}, fn v, {out, acc} ->
        {s, acc} = value(v, lib, acc)
        {[s | out], acc}
      end)

    {Enum.reverse(out), acc}
  end

  defp value(nil, _lib, acc), do: {"null", acc}
  defp value(v, _lib, acc) when is_binary(v), do: {Jason.encode!(v), acc}
  defp value(true, _lib, acc), do: {"true", acc}
  defp value(false, _lib, acc), do: {"false", acc}

  defp value(v, _lib, acc) when is_number(v) or v in [:infinity, :neg_infinity, :nan],
    do: {number(v), acc}

  defp value(%Element{statement_id: id} = el, lib, acc) when is_binary(id) do
    if List.keymember?(acc, id, 0) do
      {id, acc}
    else
      {text, acc} = element_expr(el, lib, acc)
      {id, [{id, text} | acc]}
    end
  end

  defp value(%Element{} = el, lib, acc), do: element_expr(el, lib, acc)
  defp value(%Binding{target: t}, _lib, acc), do: {t, acc}
  defp value(%ActionPlan{steps: [step]}, lib, acc), do: {step(step, lib), acc}

  defp value(%ActionPlan{steps: steps}, lib, acc),
    do: {"Action([" <> Enum.map_join(steps, ", ", &step(&1, lib)) <> "])", acc}

  defp value(list, lib, acc) when is_list(list) do
    {items, acc} = map_values(list, lib, acc)
    {"[" <> Enum.join(items, ", ") <> "]", acc}
  end

  defp value(map, lib, acc) when is_map(map) do
    {entries, acc} =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({[], acc}, fn {k, v}, {out, acc} ->
        {s, acc} = value(v, lib, acc)
        {["#{key(k)}: #{s}" | out], acc}
      end)

    {"{" <> Enum.join(Enum.reverse(entries), ", ") <> "}", acc}
  end

  defp value(ast, lib, acc) when is_tuple(ast), do: {ast(ast, lib), acc}

  defp number(:nan), do: "null"
  defp number(:infinity), do: "1e999"
  defp number(:neg_infinity), do: "-1e999"
  defp number(n), do: JS.number_to_string(n)

  defp key(k) do
    if Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, k) and k not in ["true", "false", "null"],
      do: k,
      else: Jason.encode!(k)
  end

  defp step({:continue_conversation, msg, :none}, _lib), do: "@ToAssistant(#{Jason.encode!(msg)})"

  defp step({:continue_conversation, msg, ctx}, lib),
    do: "@ToAssistant(#{Jason.encode!(msg)}, #{elem(value(ctx, lib, []), 0)})"

  defp step({:open_url, url}, _lib), do: "@OpenUrl(#{Jason.encode!(url)})"
  defp step({:set, target, ast}, lib), do: "@Set(#{target}, #{ast(ast, lib)})"
  defp step({:reset, targets}, _lib), do: "@Reset(#{Enum.join(targets, ", ")})"
  defp step({:run, id, _}, _lib), do: "@Run(#{id})"

  defp step({:custom, name, params, order}, lib) do
    args = Enum.map(order, &elem(value(Map.get(params, &1), lib, []), 0))
    "@#{name}(#{Enum.join(args, ", ")})"
  end

  # ── AST ──────────────────────────────────────────────────────────────────

  @doc "Serializes an AST node."
  def ast({:str, v}, _lib), do: Jason.encode!(v)
  def ast({:num, v}, _lib), do: number(v)
  def ast({:bool, v}, _lib), do: to_string(v)
  def ast({:null}, _lib), do: "null"
  def ast({:const, v}, lib), do: elem(value(v, lib, []), 0)
  def ast({:ph, n}, _lib), do: n
  def ast({:state, n}, _lib), do: n
  def ast({:ref, n}, _lib), do: n
  def ast({:rref, n, _}, _lib), do: n
  def ast({:arr, els}, lib), do: "[" <> Enum.map_join(els, ", ", &ast(&1, lib)) <> "]"

  def ast({:obj, entries}, lib),
    do: "{" <> Enum.map_join(entries, ", ", fn {k, v} -> "#{key(k)}: #{ast(v, lib)}" end) <> "}"

  def ast({:bin, op, l, r}, lib) do
    p = Map.fetch!(@precedence, op)
    "#{child(l, p, :left, lib)} #{op} #{child(r, p, :right, lib)}"
  end

  def ast({:unary, op, x}, lib) do
    inner = ast(x, lib)

    if match?({:bin, _, _, _}, x) or match?({:ternary, _, _, _}, x),
      do: "#{op}(#{inner})",
      else: op <> inner
  end

  def ast({:ternary, c, t, e}, lib) do
    cond_s = if match?({:ternary, _, _, _}, c), do: "(#{ast(c, lib)})", else: ast(c, lib)
    "#{cond_s} ? #{ast(t, lib)} : #{ast(e, lib)}"
  end

  def ast({:member, o, f}, lib), do: "#{postfix_obj(o, lib)}.#{f}"
  def ast({:index, o, i}, lib), do: "#{postfix_obj(o, lib)}[#{ast(i, lib)}]"
  def ast({:assign, t, v}, lib), do: "#{t} = #{ast(v, lib)}"

  def ast({:call, name, args, _fn?, _mapped}, lib) do
    rendered = Enum.map_join(args, ", ", &ast(&1, lib))

    call_name =
      if name != "Action" and (Builtins.builtin?(name) or Library.get_call(lib, name)),
        do: "@" <> name,
        else: name

    "#{call_name}(#{rendered})"
  end

  def ast(_other, _lib), do: "null"

  # Binary operators are left-associative: a right operand of equal precedence needs parentheses.
  defp child({:bin, op, _, _} = node, parent, side, lib) do
    p = Map.fetch!(@precedence, op)
    inner = ast(node, lib)
    if p < parent or (p == parent and side == :right), do: "(#{inner})", else: inner
  end

  defp child({:ternary, _, _, _} = node, _parent, _side, lib), do: "(#{ast(node, lib)})"
  defp child(node, _parent, _side, lib), do: ast(node, lib)

  defp postfix_obj(node, lib) do
    case node do
      {kind, _, _, _} when kind in [:bin, :ternary] -> "(#{ast(node, lib)})"
      {:unary, _, _} -> "(#{ast(node, lib)})"
      _ -> ast(node, lib)
    end
  end
end
