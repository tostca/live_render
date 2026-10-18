defmodule LiveRender.OpenUI.ExprParser do
  @moduledoc """
  Pratt parser for OpenUI Lang expressions (language.md, sections 1.5 and 1.6).

  AST nodes are tuples:

      {:str, s} {:num, n} {:bool, b} {:null}
      {:arr, [node]} {:obj, [{key, node}]}
      {:ref, name} {:ph, name} {:state, "$name"} {:rref, name, :query | :mutation}
      {:bin, op, left, right} {:unary, op, operand} {:ternary, cond, then, else}
      {:member, obj, field} {:index, obj, index} {:assign, "$name", value}
      {:call, name, args, fn?, mapped}

  `fn?` is true for an `@Name(...)` call whose name is not a built-in. `mapped` is nil until the
  materializer names the arguments: a list of `{param, node}`.

  Parsing never fails. An unexpected token becomes `{:null}`, nesting deeper than
  `#{200}` levels is cut off, and tokens after a complete expression are ignored.
  """

  alias LiveRender.OpenUI.{Builtins, JS}

  @max_depth 200

  @prec_ternary 1
  @prec_or 2
  @prec_and 3
  @prec_eq 4
  @prec_cmp 5
  @prec_add 6
  @prec_mul 7
  @prec_unary 8
  @prec_member 9

  @binary_ops %{
    or: {"||", @prec_or},
    and: {"&&", @prec_and},
    eqeq: {"==", @prec_eq},
    noteq: {"!=", @prec_eq},
    gt: {">", @prec_cmp},
    lt: {"<", @prec_cmp},
    gte: {">=", @prec_cmp},
    lte: {"<=", @prec_cmp},
    plus: {"+", @prec_add},
    minus: {"-", @prec_add},
    star: {"*", @prec_mul},
    slash: {"/", @prec_mul},
    percent: {"%", @prec_mul}
  }

  @doc "Parses an expression from tokens. Trailing tokens are ignored."
  @spec parse([LiveRender.OpenUI.Lexer.token()]) :: tuple()
  def parse(tokens) do
    {node, _rest} = expr(tokens, 0, 0)
    node
  end

  defp expr(tokens, _min, depth) when depth > @max_depth, do: {{:null}, drop_all(tokens)}

  defp expr(tokens, min_prec, depth) do
    {left, rest} = prefix(tokens, depth)
    infix_loop(left, rest, min_prec, depth)
  end

  defp drop_all(_tokens), do: []

  defp infix_loop(left, rest, min_prec, depth) do
    if infix_prec(rest) > min_prec do
      {left, rest} = infix(left, rest, depth)
      infix_loop(left, rest, min_prec, depth)
    else
      {left, rest}
    end
  end

  defp infix_prec([{:question, _, _} | _]), do: @prec_ternary
  defp infix_prec([{:dot, _, _} | _]), do: @prec_member
  defp infix_prec([{:lbrack, _, _} | _]), do: @prec_member

  defp infix_prec([{kind, _, _} | _]) do
    case Map.get(@binary_ops, kind) do
      {_op, prec} -> prec
      nil -> 0
    end
  end

  defp infix_prec([]), do: 0

  # ── Prefix ───────────────────────────────────────────────────────────────

  defp prefix([], _depth), do: {{:null}, []}
  defp prefix([{:str, v, _} | rest], _d), do: {{:str, v}, rest}
  defp prefix([{:num, v, _} | rest], _d), do: {{:num, v}, rest}
  defp prefix([{true, _, _} | rest], _d), do: {{:bool, true}, rest}
  defp prefix([{false, _, _} | rest], _d), do: {{:bool, false}, rest}
  defp prefix([{:null, _, _} | rest], _d), do: {{:null}, rest}
  defp prefix([{:lbrack, _, _} | rest], d), do: array(rest, [], d + 1)
  defp prefix([{:lbrace, _, _} | rest], d), do: object(rest, [], d + 1)

  defp prefix([{:state, name, _}, {:equals, _, _} | rest], d) do
    {value, rest} = expr(rest, 0, d + 1)
    {{:assign, name, value}, rest}
  end

  defp prefix([{:state, name, _} | rest], _d), do: {{:state, name}, rest}

  defp prefix([{:type, name, _}, {:lparen, _, _} | rest] = tokens, d) do
    if Builtins.builtin?(name) and name != "Action",
      do: {{:ref, name}, tl(tokens)},
      else: call(name, false, rest, d + 1)
  end

  defp prefix([{:type, name, _} | rest], _d), do: {{:ref, name}, rest}

  defp prefix([{:builtin, name, _}, {:lparen, _, _} | rest], d),
    do: call(name, not Builtins.builtin?(name), rest, d + 1)

  defp prefix([{:builtin, name, _} | rest], _d), do: {{:ref, name}, rest}
  defp prefix([{:ident, name, _} | rest], _d), do: {{:ref, name}, rest}

  defp prefix([{:not, _, _} | rest], d) do
    {operand, rest} = expr(rest, @prec_unary, d + 1)
    {{:unary, "!", operand}, rest}
  end

  defp prefix([{:minus, _, _} | rest], d) do
    {operand, rest} = expr(rest, @prec_unary, d + 1)
    {{:unary, "-", operand}, rest}
  end

  defp prefix([{:lparen, _, _} | rest], d) do
    {inner, rest} = expr(rest, 0, d + 1)
    {inner, eat(rest, :rparen)}
  end

  # An unexpected token is skipped and reads as null.
  defp prefix([_ | rest], _d), do: {{:null}, rest}

  # ── Infix and postfix ────────────────────────────────────────────────────

  defp infix(cond_node, [{:question, _, _} | rest], d) do
    {then_node, rest} = expr(rest, 0, d + 1)
    rest = eat(rest, :colon)
    {else_node, rest} = expr(rest, 0, d + 1)
    {{:ternary, cond_node, then_node, else_node}, rest}
  end

  defp infix(obj, [{:dot, _, _} | rest], _d) do
    {field, rest} =
      case rest do
        [{kind, v, _} | rest] when kind in [:ident, :type, :str] -> {v, rest}
        [{:num, v, _} | rest] -> {JS.number_to_string(v), rest}
        [{:state, "$" <> name, _} | rest] -> {name, rest}
        [_ | rest] -> {"?", rest}
        [] -> {"?", []}
      end

    {{:member, obj, field}, rest}
  end

  defp infix(obj, [{:lbrack, _, _} | rest], d) do
    {index, rest} = expr(rest, 0, d + 1)
    {{:index, obj, index}, eat(rest, :rbrack)}
  end

  defp infix(left, [{kind, _, _} | rest], d) do
    {op, prec} = Map.fetch!(@binary_ops, kind)
    {right, rest} = expr(rest, prec, d + 1)
    {{:bin, op, left, right}, rest}
  end

  # ── Compound forms ───────────────────────────────────────────────────────

  defp call(name, fn?, tokens, d) do
    {args, rest} = elements(tokens, :rparen, [], d)
    {{:call, name, args, fn?, nil}, rest}
  end

  defp array(tokens, _acc, d) do
    {els, rest} = elements(tokens, :rbrack, [], d)
    {{:arr, els}, rest}
  end

  # Arguments and array elements: commas between them are optional, trailing commas ignored.
  defp elements([], _close, acc, _d), do: {Enum.reverse(acc), []}
  defp elements([{close, _, _} | rest], close, acc, _d), do: {Enum.reverse(acc), rest}

  defp elements(tokens, close, acc, d) do
    {node, rest} = expr(tokens, 0, d)
    elements(eat(rest, :comma), close, [node | acc], d)
  end

  defp object([], acc, _d), do: {{:obj, Enum.reverse(acc)}, []}
  defp object([{:rbrace, _, _} | rest], acc, _d), do: {{:obj, Enum.reverse(acc)}, rest}

  defp object(tokens, acc, d) do
    {key, rest} =
      case tokens do
        [{kind, v, _} | rest] when kind in [:ident, :str, :type] -> {v, rest}
        [{:num, v, _} | rest] -> {JS.number_to_string(v), rest}
        [{:state, "$" <> name, _} | rest] -> {name, rest}
        [_ | rest] -> {"?", rest}
      end

    rest = eat(rest, :colon)
    {value, rest} = expr(rest, 0, d)
    object(eat(rest, :comma), [{key, value} | acc], d)
  end

  defp eat([{kind, _, _} | rest], kind), do: rest
  defp eat(tokens, _kind), do: tokens
end
