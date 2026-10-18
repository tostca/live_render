defmodule LiveRender.OpenUI.Lexer do
  @moduledoc """
  Tokenizer for OpenUI Lang (language.md, section 1.3). Lexing never fails: a character that
  matches no rule is skipped.

  A token is `{kind, value, offset}`, where `offset` is the byte offset of the token's first
  character. Kinds:

      :newline :lparen :rparen :lbrack :rbrack :lbrace :rbrace :comma :colon :equals
      :true :false :null :str :num :ident :type :state :builtin
      :dot :plus :minus :star :slash :percent :eqeq :noteq :gt :lt :gte :lte
      :and :or :not :question

  `:ident` is a name starting with a lowercase letter or `_`, `:type` one starting with an
  uppercase letter, `:state` a `$name` (value includes the `$`), `:builtin` an `@name` (value
  without the `@`).
  """

  alias LiveRender.OpenUI.JS

  @type kind :: atom()
  @type token :: {kind(), term(), non_neg_integer()}

  @json_stops ["\\" | Enum.map(0..0x1F, &<<&1>>)]

  @value_kinds [:num, :str, :ident, :type, :rparen, :rbrack, true, false, :null, :state, :builtin]

  @doc "Tokenizes `src`. The result never contains an EOF token."
  @spec tokenize(String.t(), non_neg_integer()) :: [token()]
  def tokenize(src, base_offset \\ 0) do
    src |> lex(base_offset, nil, []) |> Enum.reverse()
  end

  defguardp is_alpha(c) when c in ?a..?z or c in ?A..?Z or c == ?_
  defguardp is_ident_char(c) when is_alpha(c) or c in ?0..?9
  defguardp is_digit(c) when c in ?0..?9

  defp lex(<<>>, _pos, _prev, acc), do: acc

  defp lex(<<c, rest::binary>>, pos, prev, acc) when c in [?\s, ?\t, ?\r],
    do: lex(rest, pos + 1, prev, acc)

  defp lex(<<"\n", rest::binary>>, pos, _prev, acc),
    do: emit(rest, pos + 1, {:newline, nil, pos}, acc)

  defp lex(<<"==", rest::binary>>, pos, _p, acc), do: emit(rest, pos + 2, {:eqeq, nil, pos}, acc)
  defp lex(<<"!=", rest::binary>>, pos, _p, acc), do: emit(rest, pos + 2, {:noteq, nil, pos}, acc)
  defp lex(<<">=", rest::binary>>, pos, _p, acc), do: emit(rest, pos + 2, {:gte, nil, pos}, acc)
  defp lex(<<"<=", rest::binary>>, pos, _p, acc), do: emit(rest, pos + 2, {:lte, nil, pos}, acc)
  defp lex(<<"&&", rest::binary>>, pos, _p, acc), do: emit(rest, pos + 2, {:and, nil, pos}, acc)
  defp lex(<<"||", rest::binary>>, pos, _p, acc), do: emit(rest, pos + 2, {:or, nil, pos}, acc)

  defp lex(<<c, rest::binary>>, pos, prev, acc)
       when c in [?(, ?), ?[, ?], ?{, ?}, ?,, ?:, ?=, ?!, ?>, ?<, ?&, ?|, ?., ??, ?+, ?*, ?/, ?%] do
    _ = prev
    emit(rest, pos + 1, {punct(c), nil, pos}, acc)
  end

  defp lex(<<"\"", rest::binary>>, pos, _prev, acc) do
    {value, consumed} = lex_double_string(rest)

    emit(
      binary_part(rest, consumed, byte_size(rest) - consumed),
      pos + 1 + consumed,
      {:str, value, pos},
      acc
    )
  end

  defp lex(<<"'", rest::binary>>, pos, _prev, acc) do
    {value, consumed} = lex_single_string(rest, [], 0)

    emit(
      binary_part(rest, consumed, byte_size(rest) - consumed),
      pos + 1 + consumed,
      {:str, value, pos},
      acc
    )
  end

  defp lex(<<"-", d, _::binary>> = src, pos, prev, acc) when is_digit(d) do
    if prev in @value_kinds do
      <<_, rest::binary>> = src
      emit(rest, pos + 1, {:minus, nil, pos}, acc)
    else
      lex_number(src, pos, acc)
    end
  end

  defp lex(<<"-", rest::binary>>, pos, _prev, acc),
    do: emit(rest, pos + 1, {:minus, nil, pos}, acc)

  defp lex(<<d, _::binary>> = src, pos, _prev, acc) when is_digit(d),
    do: lex_number(src, pos, acc)

  defp lex(<<"$", c, _::binary>> = src, pos, _prev, acc) when is_alpha(c) do
    <<_, rest::binary>> = src
    {name, rest} = take_ident(rest)
    emit(rest, pos + 1 + byte_size(name), {:state, "$" <> name, pos}, acc)
  end

  defp lex(<<"@", c, _::binary>> = src, pos, _prev, acc) when is_alpha(c) do
    <<_, rest::binary>> = src
    {name, rest} = take_ident(rest)
    emit(rest, pos + 1 + byte_size(name), {:builtin, name, pos}, acc)
  end

  defp lex(<<c, _::binary>> = src, pos, _prev, acc) when is_alpha(c) do
    {word, rest} = take_ident(src)
    next = pos + byte_size(word)

    token =
      case word do
        "true" -> {true, true, pos}
        "false" -> {false, false, pos}
        "null" -> {:null, nil, pos}
        <<first, _::binary>> when first in ?A..?Z -> {:type, word, pos}
        _ -> {:ident, word, pos}
      end

    emit(rest, next, token, acc)
  end

  # Any other character is skipped.
  defp lex(<<_c, rest::binary>>, pos, prev, acc), do: lex(rest, pos + 1, prev, acc)

  defp emit(rest, pos, {kind, _, _} = token, acc), do: lex(rest, pos, kind, [token | acc])

  defp punct(?(), do: :lparen
  defp punct(?)), do: :rparen
  defp punct(?[), do: :lbrack
  defp punct(?]), do: :rbrack
  defp punct(?{), do: :lbrace
  defp punct(?}), do: :rbrace
  defp punct(?,), do: :comma
  defp punct(?:), do: :colon
  defp punct(?=), do: :equals
  defp punct(?!), do: :not
  defp punct(?>), do: :gt
  defp punct(?<), do: :lt
  # A single & or | means && or ||.
  defp punct(?&), do: :and
  defp punct(?|), do: :or
  defp punct(?.), do: :dot
  defp punct(??), do: :question
  defp punct(?+), do: :plus
  defp punct(?*), do: :star
  defp punct(?/), do: :slash
  defp punct(?%), do: :percent

  defp take_ident(src), do: take_ident(src, 0, src)

  defp take_ident(<<c, rest::binary>>, n, src) when is_ident_char(c),
    do: take_ident(rest, n + 1, src)

  defp take_ident(_rest, n, src),
    do: {binary_part(src, 0, n), binary_part(src, n, byte_size(src) - n)}

  # ── Numbers ──────────────────────────────────────────────────────────────

  # -?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)? ; an `e` after the digits is always an exponent marker.
  defp lex_number(src, pos, acc) do
    len = number_length(src)
    text = binary_part(src, 0, len)
    rest = binary_part(src, len, byte_size(src) - len)
    emit(rest, pos + len, {:num, number_value(text), pos}, acc)
  end

  defp number_length(src) do
    n = if match?(<<"-", _::binary>>, src), do: 1, else: 0
    n = n + digits_length(skip(src, n))

    n =
      case skip(src, n) do
        <<".", d, _::binary>> when is_digit(d) -> n + 1 + digits_length(skip(src, n + 1))
        _ -> n
      end

    case skip(src, n) do
      <<e, s, _::binary>> when e in [?e, ?E] and s in [?+, ?-] ->
        n + 2 + digits_length(skip(src, n + 2))

      <<e, _::binary>> when e in [?e, ?E] ->
        n + 1 + digits_length(skip(src, n + 1))

      _ ->
        n
    end
  end

  defp skip(src, n), do: binary_part(src, n, byte_size(src) - n)

  defp digits_length(<<d, rest::binary>>) when is_digit(d), do: 1 + digits_length(rest)
  defp digits_length(_), do: 0

  # A number with a dangling exponent (`1e`) is not a usable number; it reads as NaN, as `+"1e"`
  # does in JavaScript (implementation-defined in 1.0).
  defp number_value(text) do
    if Regex.match?(~r/[eE][+-]?\z/, text), do: :nan, else: JS.ecma_to_number(text)
  end

  # ── Strings ──────────────────────────────────────────────────────────────

  # Double-quoted strings use JSON escapes. Returns {value, bytes consumed after the opening quote}.
  # When the content is not valid JSON (a raw newline, an unknown escape), the raw text between the
  # quotes is kept, so a model's mistake never loses text.
  defp lex_double_string(src) do
    {raw_len, closed?} = double_string_extent(src, 0)
    raw = binary_part(src, 0, raw_len)
    consumed = if closed?, do: raw_len + 1, else: raw_len

    value =
      case json_unescape(raw) do
        {:ok, value} -> value
        :error -> raw
      end

    {value, consumed}
  end

  # Jumps from one quote or backslash to the next, so long strings lex in linear time.
  defp double_string_extent(src, n) do
    size = byte_size(src)

    case :binary.match(src, ["\"", "\\"], scope: {n, size - n}) do
      :nomatch ->
        {size, false}

      {pos, 1} ->
        cond do
          :binary.at(src, pos) == ?" -> {pos, true}
          pos + 1 < size -> double_string_extent(src, pos + 2)
          true -> {pos + 1, false}
        end
    end
  end

  @doc false
  def json_unescape(raw), do: json_unescape(raw, [])

  defp json_unescape(<<>>, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp json_unescape(<<"\\u", h::binary-size(4), rest::binary>>, acc) do
    case Integer.parse(h, 16) do
      {cp, ""} when cp in 0xD800..0xDBFF ->
        case rest do
          <<"\\u", l::binary-size(4), rest2::binary>> ->
            case Integer.parse(l, 16) do
              {low, ""} when low in 0xDC00..0xDFFF ->
                code = 0x10000 + Bitwise.bsl(cp - 0xD800, 10) + (low - 0xDC00)
                json_unescape(rest2, [<<code::utf8>> | acc])

              _ ->
                json_unescape(rest, [<<0xFFFD::utf8>> | acc])
            end

          _ ->
            json_unescape(rest, [<<0xFFFD::utf8>> | acc])
        end

      {cp, ""} when cp in 0xDC00..0xDFFF ->
        json_unescape(rest, [<<0xFFFD::utf8>> | acc])

      {cp, ""} ->
        json_unescape(rest, [<<cp::utf8>> | acc])

      _ ->
        :error
    end
  end

  defp json_unescape(<<"\\", c, rest::binary>>, acc) do
    case c do
      ?" -> json_unescape(rest, ["\"" | acc])
      ?\\ -> json_unescape(rest, ["\\" | acc])
      ?/ -> json_unescape(rest, ["/" | acc])
      ?b -> json_unescape(rest, ["\b" | acc])
      ?f -> json_unescape(rest, ["\f" | acc])
      ?n -> json_unescape(rest, ["\n" | acc])
      ?r -> json_unescape(rest, ["\r" | acc])
      ?t -> json_unescape(rest, ["\t" | acc])
      _ -> :error
    end
  end

  defp json_unescape(<<"\\">>, _acc), do: :error
  defp json_unescape(<<c, _rest::binary>>, _acc) when c < 0x20, do: :error

  # A run of plain characters up to the next backslash or control character.
  defp json_unescape(bin, acc) do
    len =
      case :binary.match(bin, @json_stops) do
        :nomatch -> byte_size(bin)
        {pos, _} -> pos
      end

    <<run::binary-size(len), rest::binary>> = bin
    json_unescape(rest, [run | acc])
  end

  # Single-quoted strings support only \', \\, \n and \t; any other escaped character is kept as is.
  defp lex_single_string(<<>>, acc, n), do: {finish(acc), n}
  defp lex_single_string(<<"'", _::binary>>, acc, n), do: {finish(acc), n + 1}
  defp lex_single_string(<<"\\">>, acc, n), do: {finish(acc), n + 1}

  defp lex_single_string(<<"\\", c, rest::binary>>, acc, n) do
    char =
      case c do
        ?' -> "'"
        ?\\ -> "\\"
        ?n -> "\n"
        ?t -> "\t"
        other -> <<other>>
      end

    lex_single_string(rest, [char | acc], n + 2)
  end

  defp lex_single_string(bin, acc, n) do
    len =
      case :binary.match(bin, ["'", "\\"]) do
        :nomatch -> byte_size(bin)
        {pos, _} -> pos
      end

    <<run::binary-size(len), rest::binary>> = bin
    lex_single_string(rest, [run | acc], n + len)
  end

  defp finish(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end
