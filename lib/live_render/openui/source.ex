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

  # Text that starts a statement (`name =` or `$name =`).
  @statement_start ~r/^\s*\$?[A-Za-z_]\w*\s*=(?!=)/
  # A line that starts with ```, then an optional tag and the rest of the line.
  @fence_line ~r/^[ \t]*```[ \t]*([\w.+-]*)[ \t]*(.*?)[ \t]*\r?$/
  @leading_comments ~r/^(\s*(\/\/|#)[^\n]*\n)+/

  @doc """
  Extracts the program from markdown code fences (language.md 1.1, section 1.2), or returns the
  text unchanged when no fence holds one.

  Fences are matched by line. A fence line opens a block and the next fence line closes it; an
  unterminated block runs to the end of the text. A ``` pair on one line is inline code. Code may
  follow the tag on the opener line. `openui-js` blocks are scripts and are skipped. When a block's
  first code line starts a statement, the program is every block joined with newlines; otherwise
  text outside the blocks that holds a statement is the program. A fence line inside a
  double-quoted string is part of the string; outside blocks only statement lines and their
  continuation lines are scanned, so a quote in prose does not count.
  """
  @spec strip_fences(String.t()) :: String.t()
  def strip_fences(text) do
    if String.contains?(text, "```"), do: extract_fences(text), else: text
  end

  defp extract_fences(text) do
    init = %{blocks: [], outside: [], body: nil, script: false, open: false, depth: 0}

    st =
      text
      |> String.split("\n")
      |> Enum.reduce(init, fn line, st ->
        fence = if st.open, do: nil, else: Regex.run(@fence_line, line)
        fence_step(fence, line, st)
      end)

    blocks =
      if st.body != nil and not st.script,
        do: [Enum.reverse(st.body) |> Enum.join("\n") | st.blocks],
        else: st.blocks

    blocks = Enum.reverse(blocks)
    outside = Enum.reverse(st.outside)

    cond do
      Enum.any?(blocks, &starts_program?/1) -> Enum.join(blocks, "\n")
      Enum.any?(outside, &statement_start?/1) -> Enum.join(outside, "\n")
      Enum.all?(blocks, &(JS.trim(&1) == "")) -> Enum.join(outside, "\n")
      true -> Enum.join(blocks, "\n")
    end
  end

  # A code or prose line.
  defp fence_step(nil, _line, %{script: true} = st), do: st

  defp fence_step(nil, line, st) do
    st =
      if st.body == nil,
        do: %{st | outside: [line | st.outside]},
        else: %{st | body: [line | st.body]}

    # Code lines are scanned for strings and brackets: every line inside a block, and outside one
    # a statement and its continuation lines.
    if st.open or st.depth > 0 or st.body != nil or statement_start?(line),
      do: scan_code(line, st),
      else: st
  end

  # A fence line ends any statement. Inside a block, it closes the block; what follows is ignored.
  defp fence_step(_fence, _line, %{body: body} = st) when body != nil do
    blocks =
      if st.script, do: st.blocks, else: [Enum.reverse(body) |> Enum.join("\n") | st.blocks]

    %{st | blocks: blocks, body: nil, script: false, depth: 0}
  end

  defp fence_step([_, tag, rest], _line, st) do
    st = %{st | depth: 0}

    if String.contains?(rest, "```") do
      # A ``` pair on one line is inline code in prose.
      st
    else
      body = if code = opener_code(tag, rest), do: [code], else: []
      %{st | body: body, script: String.downcase(tag) == "openui-js"}
    end
  end

  # Code on an opener line (```openui root = ... or ```root = ...), or nil.
  defp opener_code(tag, rest) do
    cond do
      statement_start?(rest) -> rest
      tag != "" and Regex.match?(~r/^=(?!=)/, rest) -> tag <> " " <> rest
      true -> nil
    end
  end

  defp statement_start?(line), do: Regex.match?(@statement_start, line)

  defp starts_program?(block),
    do: statement_start?(Regex.replace(@leading_comments, block, "", global: false))

  # Whether a "..." string is open after the line (escapes honored), and the bracket depth.
  defp scan_code(<<>>, st), do: st
  defp scan_code(<<"\\", _c, rest::binary>>, %{open: true} = st), do: scan_code(rest, st)

  defp scan_code(<<"\"", rest::binary>>, %{open: true} = st),
    do: scan_code(rest, %{st | open: false})

  defp scan_code(<<_c, rest::binary>>, %{open: true} = st), do: scan_code(rest, st)
  defp scan_code(<<"\"", rest::binary>>, st), do: scan_code(rest, %{st | open: true})

  defp scan_code(<<c, rest::binary>>, st) when c in [?(, ?[, ?{],
    do: scan_code(rest, %{st | depth: st.depth + 1})

  defp scan_code(<<c, rest::binary>>, %{depth: d} = st) when c in [?), ?], ?}] and d > 0,
    do: scan_code(rest, %{st | depth: d - 1})

  defp scan_code(<<_c, rest::binary>>, st), do: scan_code(rest, st)

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
