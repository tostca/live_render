defmodule LiveRender.OpenUI.Source do
  @moduledoc """
  Text preparation (language.md, section 1.2) and implicit closing (section 4, rule 2).

  `prepare/1` runs, in order: message-marker extraction, fence extraction, comment stripping and
  trimming. Every byte the special characters care about is ASCII, so the scanners walk bytes;
  multi-byte UTF-8 sequences pass through untouched.
  """

  alias LiveRender.OpenUI.{JS, Protocol}

  @doc "Prepares raw model output for the lexer. `streaming: true` holds back partial markers."
  @spec prepare(String.t(), keyword()) :: String.t()
  def prepare(text, opts \\ []) do
    text
    |> Protocol.content(opts)
    |> strip_fences()
    |> strip_comments()
    |> JS.trim()
  end

  # ── Fences ───────────────────────────────────────────────────────────────

  @doc """
  Joins the contents of every fence with newlines, or returns the text unchanged when it has no
  fence. A fence opens only with three backticks at the start of a line. Inside a fence, backticks
  in double-quoted strings do not close it; single quotes do not shield. An unterminated fence runs
  to the end of the text.
  """
  @spec strip_fences(String.t()) :: String.t()
  def strip_fences(text) do
    case collect_fences(text, true, []) do
      [] -> text
      blocks -> blocks |> Enum.reverse() |> Enum.join("\n")
    end
  end

  # Scans prose for a line that starts with ```.
  defp collect_fences(<<>>, _line_start, acc), do: acc

  defp collect_fences(<<"```", rest::binary>>, true, acc) do
    case :binary.split(rest, "\n") do
      [_tag] ->
        # The opener's line has not ended yet (streaming): the fence is empty so far.
        ["" | acc]

      [_tag, body] ->
        {content, after_fence} = scan_fence_body(body, body, 0)
        acc = [content | acc]

        case after_fence do
          nil -> acc
          rest_text -> collect_fences(rest_text, false, acc)
        end
    end
  end

  defp collect_fences(<<"\n", rest::binary>>, _line_start, acc),
    do: collect_fences(rest, true, acc)

  defp collect_fences(<<c, rest::binary>>, true, acc) when c in [?\s, ?\t],
    do: collect_fences(rest, true, acc)

  defp collect_fences(<<_c, rest::binary>>, _line_start, acc),
    do: collect_fences(rest, false, acc)

  # Returns {content, rest_after_closing_fence | nil}.
  defp scan_fence_body(body, <<>>, _pos), do: {body, nil}

  defp scan_fence_body(body, <<"```", rest::binary>>, pos),
    do: {binary_part(body, 0, pos), rest}

  defp scan_fence_body(body, <<"\"", rest::binary>>, pos) do
    skipped = skip_double_string(rest, 1)
    remaining = byte_size(rest) + 1 - skipped

    if remaining <= 0,
      do: {body, nil},
      else: scan_fence_body(body, binary_part(rest, skipped - 1, remaining), pos + skipped)
  end

  defp scan_fence_body(body, <<_c, rest::binary>>, pos), do: scan_fence_body(body, rest, pos + 1)

  # Bytes consumed by a double-quoted string after its opening quote, including the closing quote.
  defp skip_double_string(<<>>, n), do: n
  defp skip_double_string(<<"\\", _c, rest::binary>>, n), do: skip_double_string(rest, n + 2)
  defp skip_double_string(<<"\\">>, n), do: n + 1
  defp skip_double_string(<<"\"", _rest::binary>>, n), do: n + 1
  defp skip_double_string(<<_c, rest::binary>>, n), do: skip_double_string(rest, n + 1)

  # ── Comments ─────────────────────────────────────────────────────────────

  @doc """
  Removes `//` and `#` comments that run to the end of the line. Markers inside strings, including
  multi-line strings, are kept. A removed comment also takes the whitespace before it.
  """
  @spec strip_comments(String.t()) :: String.t()
  def strip_comments(text) do
    {lines, _in_str} =
      text
      |> String.split("\n")
      |> Enum.map_reduce(false, fn line, in_str -> strip_line(line, in_str) end)

    Enum.join(lines, "\n")
  end

  defp strip_line(line, in_str), do: strip_line(line, line, 0, in_str)

  defp strip_line(line, <<>>, _pos, in_str), do: {line, in_str}

  defp strip_line(line, <<"\\", _c, rest::binary>>, pos, quote) when quote != false,
    do: strip_line(line, rest, pos + 2, quote)

  defp strip_line(line, <<c, rest::binary>>, pos, quote) when quote != false do
    if c == quote,
      do: strip_line(line, rest, pos + 1, false),
      else: strip_line(line, rest, pos + 1, quote)
  end

  defp strip_line(line, <<c, rest::binary>>, pos, false) when c in [?", ?'],
    do: strip_line(line, rest, pos + 1, c)

  defp strip_line(line, <<"//", _::binary>>, pos, false), do: {cut(line, pos), false}
  defp strip_line(line, <<"#", _::binary>>, pos, false), do: {cut(line, pos), false}

  defp strip_line(line, <<_c, rest::binary>>, pos, false),
    do: strip_line(line, rest, pos + 1, false)

  defp cut(line, pos), do: line |> binary_part(0, pos) |> String.trim_trailing()

  # ── Implicit closing ─────────────────────────────────────────────────────

  @doc """
  Closes an unterminated string (adding a `\\` first when the text ends mid-escape), then closes
  unclosed brackets in reverse order. A closing bracket that does not match is skipped and leaves
  the stack alone. Returns `{text, incomplete?}`.
  """
  @spec auto_close(String.t()) :: {String.t(), boolean()}
  def auto_close(text) do
    {stack, in_str, escaped} = close_scan(text, [], false, false)

    if in_str == false and stack == [] do
      {text, false}
    else
      {text <> string_closer(in_str, escaped) <> Enum.map_join(stack, &closer/1), true}
    end
  end

  # Text that ends mid-escape gets a `\\` first, so the added quote is not escaped.
  defp string_closer(false, _escaped), do: ""
  defp string_closer(quote, true), do: "\\" <> <<quote>>
  defp string_closer(quote, false), do: <<quote>>

  defp closer(?(), do: ")"
  defp closer(?[), do: "]"
  defp closer(?{), do: "}"

  defp close_scan(<<>>, stack, in_str, escaped), do: {stack, in_str, escaped}

  defp close_scan(<<_c, rest::binary>>, stack, in_str, true),
    do: close_scan(rest, stack, in_str, false)

  defp close_scan(<<"\\", rest::binary>>, stack, in_str, false) when in_str != false,
    do: close_scan(rest, stack, in_str, true)

  defp close_scan(<<c, rest::binary>>, stack, in_str, false) when in_str != false do
    if c == in_str,
      do: close_scan(rest, stack, false, false),
      else: close_scan(rest, stack, in_str, false)
  end

  defp close_scan(<<c, rest::binary>>, stack, false, false) when c in [?", ?'],
    do: close_scan(rest, stack, c, false)

  defp close_scan(<<c, rest::binary>>, stack, false, false) when c in [?(, ?[, ?{],
    do: close_scan(rest, [c | stack], false, false)

  defp close_scan(<<?), rest::binary>>, [?( | stack], false, false),
    do: close_scan(rest, stack, false, false)

  defp close_scan(<<?], rest::binary>>, [?[ | stack], false, false),
    do: close_scan(rest, stack, false, false)

  defp close_scan(<<?}, rest::binary>>, [?{ | stack], false, false),
    do: close_scan(rest, stack, false, false)

  defp close_scan(<<_c, rest::binary>>, stack, false, false),
    do: close_scan(rest, stack, false, false)
end
