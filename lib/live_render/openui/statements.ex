defmodule LiveRender.OpenUI.Statements do
  @moduledoc """
  Splits a token list into statements (language.md, section 1.4).

  A statement is `name = expression`. It continues past a newline when the newline is inside an
  unclosed bracket (strings are single tokens, so newlines in them never appear here), or while a
  ternary is open: from its `?` until the first complete operand after its matching `:`, or when
  the next line's first token is `?`. A line without the `name =` shape is skipped up to the next
  newline.

  The batch parser, the streaming parser and the edit merge all use `split/1`, so they agree on
  boundaries byte for byte.
  """

  defmodule Raw do
    @moduledoc """
    A statement before expression parsing.

      * `stop`: offset of the newline that ended it, or nil when the input ended first
      * `confirmed`: true when the next line's first token has arrived and is not `?`, so the
        statement can no longer be extended (section 4, rule 1)
    """
    defstruct [:id, :id_kind, :tokens, :start, :stop, confirmed: false]

    @type t :: %__MODULE__{
            id: String.t(),
            id_kind: :ident | :type | :state,
            tokens: [LiveRender.OpenUI.Lexer.token()],
            start: non_neg_integer(),
            stop: non_neg_integer() | nil,
            confirmed: boolean()
          }
  end

  @operand_kinds [:str, :num, true, false, :null, :ident, :type, :state, :builtin]

  @doc "Splits tokens into raw statements, in source order."
  @spec split([LiveRender.OpenUI.Lexer.token()]) :: [Raw.t()]
  def split(tokens), do: tokens |> do_split([]) |> Enum.reverse()

  defp do_split([], acc), do: acc
  defp do_split([{:newline, _, _} | rest], acc), do: do_split(rest, acc)

  defp do_split([{kind, id, start}, {:equals, _, _} | rest], acc)
       when kind in [:ident, :type, :state] do
    {expr, rest, stop, confirmed} = collect(rest, [], 0, 0, false)

    acc =
      case expr do
        [] ->
          acc

        _ ->
          [
            %Raw{
              id: id,
              id_kind: kind,
              tokens: expr,
              start: start,
              stop: stop,
              confirmed: confirmed
            }
            | acc
          ]
      end

    do_split(rest, acc)
  end

  defp do_split(tokens, acc), do: tokens |> skip_line() |> do_split(acc)

  defp skip_line([]), do: []
  defp skip_line([{:newline, _, _} | _] = rest), do: rest
  defp skip_line([_ | rest]), do: skip_line(rest)

  # Returns {expression tokens, rest, stop offset | nil, confirmed?}.
  defp collect([], acc, _depth, _ternary, _need), do: {Enum.reverse(acc), [], nil, false}

  defp collect([{:newline, _, pos} | rest] = tokens, acc, depth, ternary, need) do
    if depth <= 0 and ternary <= 0 and not need do
      case next_significant(rest) do
        {:question, _, _} -> collect(rest, acc, depth, ternary, need)
        nil -> {Enum.reverse(acc), tokens, pos, false}
        _ -> {Enum.reverse(acc), tokens, pos, true}
      end
    else
      collect(rest, acc, depth, ternary, need)
    end
  end

  defp collect([{kind, _, _} = tok | rest], acc, depth, ternary, need) do
    {depth, ternary, need} = track(kind, depth, ternary, need)
    collect(rest, [tok | acc], depth, ternary, need)
  end

  defp track(kind, depth, ternary, _need) when kind in [:lparen, :lbrack, :lbrace],
    do: {depth + 1, ternary, true}

  defp track(kind, depth, ternary, need) when kind in [:rparen, :rbrack, :rbrace] do
    cond do
      depth > 1 -> {depth - 1, ternary, need}
      depth == 1 -> {0, ternary, false}
      true -> {0, ternary, need}
    end
  end

  defp track(:question, 0, ternary, _need), do: {0, ternary + 1, true}
  defp track(:colon, 0, ternary, _need) when ternary > 0, do: {0, ternary - 1, true}
  defp track(kind, 0, ternary, _need) when kind in @operand_kinds, do: {0, ternary, false}
  defp track(_kind, depth, ternary, need), do: {depth, ternary, need}

  defp next_significant([]), do: nil
  defp next_significant([{:newline, _, _} | rest]), do: next_significant(rest)
  defp next_significant([tok | _]), do: tok
end
