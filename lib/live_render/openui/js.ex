defmodule LiveRender.OpenUI.JS do
  @moduledoc """
  The JavaScript value semantics OpenUI 1.0 defines in ECMA-262 terms (language.md, section 3.1).

  OpenUI numbers are IEEE doubles. Here a number is an integer when it is integral and within
  ±2^53, a float otherwise, or one of `:infinity`, `:neg_infinity`, `:nan` (BEAM floats cannot
  hold those). `normalize/1` keeps that invariant after every arithmetic step, so `4 / 2` is `2`
  and prints as `"2"`, as in JavaScript.

  Two conversions exist on purpose:

    * `to_number/1` is the spec's `toNumber`: strings that do not parse become `0`, so NaN never
      appears in arithmetic or comparisons.
    * `ecma_to_number/1` is ECMA-262 ToNumber, which can return `:nan`. Loose equality and
      `@Sort`'s numeric test use it.
  """

  alias LiveRender.OpenUI.{ActionPlan, Binding, Element}

  @max_safe 9_007_199_254_740_992

  @type number_value :: integer() | float() | :infinity | :neg_infinity | :nan

  # ECMAScript WhiteSpace and LineTerminator code points, as String.prototype.trim removes them.
  @ws [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680] ++
        Enum.to_list(0x2000..0x200A) ++ [0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]

  @doc "True for any OpenUI number value."
  defguard is_js_number(v)
           when is_integer(v) or is_float(v) or v in [:infinity, :neg_infinity, :nan]

  # ── Numbers ──────────────────────────────────────────────────────────────

  @doc "Keeps the number representation canonical: integral doubles become integers."
  @spec normalize(number_value()) :: number_value()
  def normalize(n) when is_integer(n) and (n > @max_safe or n < -@max_safe), do: n * 1.0
  def normalize(n) when is_integer(n), do: n

  def normalize(n) when is_float(n) do
    if abs(n) <= @max_safe and n == Float.floor(n), do: trunc(n), else: n
  end

  def normalize(n), do: n

  @doc """
  The spec's `toNumber`: a number is itself, a string parses or gives `0`, `true` is `1`, and
  everything else is `0`.
  """
  @spec to_number(term()) :: number_value()
  def to_number(v) when is_js_number(v), do: v
  def to_number(true), do: 1

  def to_number(v) when is_binary(v) do
    case ecma_to_number(v) do
      :nan -> 0
      n -> n
    end
  end

  def to_number(_), do: 0

  @doc "ECMA-262 ToNumber. Unlike `to_number/1` it returns `:nan`."
  @spec ecma_to_number(term()) :: number_value()
  def ecma_to_number(v) when is_js_number(v), do: v
  def ecma_to_number(nil), do: 0
  def ecma_to_number(true), do: 1
  def ecma_to_number(false), do: 0
  def ecma_to_number(v) when is_binary(v), do: string_to_number(trim(v))
  def ecma_to_number(v), do: ecma_to_number(to_primitive(v))

  defp string_to_number(""), do: 0
  defp string_to_number("Infinity"), do: :infinity
  defp string_to_number("+Infinity"), do: :infinity
  defp string_to_number("-Infinity"), do: :neg_infinity

  defp string_to_number(<<"0", x, rest::binary>>) when x in [?x, ?X] and rest != "",
    do: radix(rest, 16)

  defp string_to_number(<<"0", o, rest::binary>>) when o in [?o, ?O] and rest != "",
    do: radix(rest, 8)

  defp string_to_number(<<"0", b, rest::binary>>) when b in [?b, ?B] and rest != "",
    do: radix(rest, 2)

  defp string_to_number(s) do
    if Regex.match?(~r/\A[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?\z/, s),
      do: parse_decimal(s),
      else: :nan
  end

  defp radix(digits, base) do
    if Regex.match?(~r/\A[0-9a-zA-Z]+\z/, digits) do
      case Integer.parse(digits, base) do
        {n, ""} -> normalize(n)
        _ -> :nan
      end
    else
      :nan
    end
  end

  # Parses a string already known to match StrDecimalLiteral.
  defp parse_decimal(s) do
    {sign, body} =
      case s do
        "-" <> rest -> {-1, rest}
        "+" <> rest -> {1, rest}
        rest -> {1, rest}
      end

    {mantissa, exponent} =
      case String.split(body, ["e", "E"], parts: 2) do
        [m, e] -> {m, String.to_integer(e)}
        [m] -> {m, 0}
      end

    {int_part, frac_part} =
      case String.split(mantissa, ".", parts: 2) do
        [i, f] -> {i, f}
        [i] -> {i, ""}
      end

    digits = String.trim_leading(int_part <> frac_part, "0")
    point = exponent - byte_size(frac_part)

    cond do
      digits == "" ->
        0

      point >= 0 and byte_size(digits) + point <= 17 ->
        normalize(sign * String.to_integer(digits) * Integer.pow(10, point))

      byte_size(digits) + point > 310 ->
        if sign == 1, do: :infinity, else: :neg_infinity

      byte_size(digits) + point < -330 ->
        0

      true ->
        case Float.parse("#{digits}e#{point}") do
          {f, ""} -> normalize(sign * f)
          # Only an overflow past the largest double fails to parse (`1.8e308`).
          _ -> if sign == 1, do: :infinity, else: :neg_infinity
        end
    end
  end

  @doc "String.prototype.trim: removes ECMAScript whitespace and line terminators."
  @spec trim(String.t()) :: String.t()
  def trim(s), do: s |> trim_leading() |> trim_trailing()

  defp trim_leading(<<c::utf8, rest::binary>>) when c in @ws, do: trim_leading(rest)
  defp trim_leading(s), do: s

  # Walks back from the end one code point at a time; reversing the whole string is far slower
  # on long text.
  defp trim_trailing(s), do: binary_part(s, 0, trailing_end(s, byte_size(s)))

  defp trailing_end(_s, 0), do: 0

  defp trailing_end(s, n) do
    case last_codepoint(s, n, 1) do
      {cp, len} when cp in @ws -> trailing_end(s, n - len)
      _ -> n
    end
  end

  defp last_codepoint(_s, n, len) when len > 4 or len > n, do: nil

  defp last_codepoint(s, n, len) do
    case binary_part(s, n - len, len) do
      <<cp::utf8>> -> {cp, len}
      _ -> last_codepoint(s, n, len + 1)
    end
  end

  @doc """
  ECMAScript `parseFloat`: the longest prefix that reads as a decimal literal or `Infinity`,
  after leading whitespace. Returns `:nan` when there is none.
  """
  @spec parse_float(term()) :: number_value()
  def parse_float(v) when is_binary(v) do
    case Regex.run(~r/\A[+-]?(Infinity|(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)/, trim_leading(v)) do
      [match | _] -> string_to_number(match)
      nil -> :nan
    end
  end

  def parse_float(v) when is_js_number(v), do: v
  def parse_float(v), do: parse_float(to_string_value(v))

  @doc "True when a value is a number other than NaN."
  def number?(v) when is_js_number(v), do: v != :nan
  def number?(_), do: false

  # ── Arithmetic ───────────────────────────────────────────────────────────

  @doc "Numeric `+` on two numbers."
  def add(:nan, _), do: :nan
  def add(_, :nan), do: :nan
  def add(:infinity, :neg_infinity), do: :nan
  def add(:neg_infinity, :infinity), do: :nan
  def add(a, _) when a in [:infinity, :neg_infinity], do: a
  def add(_, b) when b in [:infinity, :neg_infinity], do: b
  def add(a, b), do: finite(fn -> a + b end, sign(a))

  @doc "Numeric `-` on two numbers."
  def sub(a, b), do: add(a, negate(b))

  @doc "Numeric `*` on two numbers."
  def mul(:nan, _), do: :nan
  def mul(_, :nan), do: :nan

  def mul(a, b) when a in [:infinity, :neg_infinity] or b in [:infinity, :neg_infinity] do
    case sign(a) * sign(b) do
      0 -> :nan
      1 -> :infinity
      -1 -> :neg_infinity
    end
  end

  def mul(a, b), do: finite(fn -> a * b end, sign(a) * sign(b))

  @doc "`/` with the spec rule that a divisor of 0 gives 0."
  def divide(a, b) do
    cond do
      zero?(b) -> 0
      a == :nan or b == :nan -> :nan
      infinite?(a) and infinite?(b) -> :nan
      infinite?(a) -> if sign(a) * sign(b) > 0, do: :infinity, else: :neg_infinity
      infinite?(b) -> 0
      true -> finite(fn -> a / b end, sign(a) * sign(b))
    end
  end

  @doc "`%` with the spec rule that a divisor of 0 gives 0. The result keeps the dividend's sign."
  def rem(a, b) do
    cond do
      zero?(b) -> 0
      a == :nan or b == :nan or infinite?(a) -> :nan
      infinite?(b) -> a
      is_integer(a) and is_integer(b) -> Kernel.rem(a, b)
      true -> normalize(:math.fmod(a * 1.0, b * 1.0))
    end
  end

  @doc "Unary minus."
  def negate(:infinity), do: :neg_infinity
  def negate(:neg_infinity), do: :infinity
  def negate(:nan), do: :nan
  def negate(n), do: normalize(-n)

  @doc "`Math.floor`."
  def floor(n) when is_integer(n) or n in [:infinity, :neg_infinity, :nan], do: n
  def floor(n), do: normalize(Float.floor(n))

  @doc "`Math.ceil`."
  def ceil(n) when is_integer(n) or n in [:infinity, :neg_infinity, :nan], do: n
  def ceil(n), do: normalize(Float.ceil(n))

  @doc "`Math.abs`."
  def abs_value(:neg_infinity), do: :infinity
  def abs_value(n) when is_atom(n), do: n
  def abs_value(n), do: normalize(Kernel.abs(n))

  @doc "`Math.round`: halves round toward +Infinity."
  def round(n) when is_integer(n) or n in [:infinity, :neg_infinity, :nan], do: n
  # Not floor(n + 0.5): that addition rounds up 0.49999999999999994 and large odd doubles.
  def round(n) do
    f = Float.floor(n)
    normalize(if n - f >= 0.5, do: f + 1.0, else: f)
  end

  @doc "`Math.pow` for the cases `@Round` needs."
  def pow(base, exp) do
    cond do
      base == :nan or exp == :nan -> :nan
      infinite?(base) or infinite?(exp) -> :nan
      true -> finite(fn -> :math.pow(base * 1.0, exp * 1.0) end, 1)
    end
  rescue
    ArithmeticError -> :nan
  end

  @doc "Numeric comparison `a < b` after both are numbers. NaN compares false."
  def less_than(a, b) do
    cond do
      a == :nan or b == :nan -> false
      a == b -> false
      a == :neg_infinity or b == :infinity -> true
      a == :infinity or b == :neg_infinity -> false
      true -> a < b
    end
  end

  @doc "Numeric equality of two numbers. NaN is never equal."
  def num_equal(a, b) do
    cond do
      a == :nan or b == :nan -> false
      is_atom(a) or is_atom(b) -> a == b
      true -> a == b
    end
  end

  defp finite(fun, overflow_sign) do
    normalize(fun.())
  rescue
    ArithmeticError -> if overflow_sign < 0, do: :neg_infinity, else: :infinity
  end

  defp zero?(b), do: b === 0 or b === +0.0 or b === -0.0

  defp infinite?(v), do: v in [:infinity, :neg_infinity]

  defp sign(:infinity), do: 1
  defp sign(:neg_infinity), do: -1
  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_), do: 0

  # ── Conversions ──────────────────────────────────────────────────────────

  @doc "JavaScript ToBoolean."
  @spec truthy?(term()) :: boolean()
  def truthy?(nil), do: false
  def truthy?(false), do: false
  def truthy?(""), do: false
  def truthy?(:nan), do: false
  def truthy?(n) when is_number(n), do: n != 0
  def truthy?(_), do: true

  @doc """
  JavaScript `String(value)`: numbers through `Number::toString`, arrays joined with `,`,
  objects and component instances as `"[object Object]"`, null as `"null"`.
  """
  @spec to_string_value(term()) :: String.t()
  def to_string_value(nil), do: "null"
  def to_string_value(true), do: "true"
  def to_string_value(false), do: "false"
  def to_string_value(v) when is_binary(v), do: v
  def to_string_value(v) when is_js_number(v), do: number_to_string(v)
  def to_string_value(v), do: v |> to_primitive() |> to_string_value()

  @doc """
  JavaScript ToPrimitive for the values OpenUI has: an array becomes its elements' strings
  joined by `,` (null becomes empty), anything else object-like becomes `"[object Object]"`.
  """
  def to_primitive(v) when is_list(v) do
    Enum.map_join(v, ",", fn
      nil -> ""
      item -> to_string_value(item)
    end)
  end

  def to_primitive(%Binding{}), do: "[object Object]"
  def to_primitive(%Element{}), do: "[object Object]"
  def to_primitive(%ActionPlan{}), do: "[object Object]"
  def to_primitive(v) when is_map(v), do: "[object Object]"
  def to_primitive(v), do: v

  @doc "ECMA-262 Number::toString(10)."
  @spec number_to_string(number_value()) :: String.t()
  def number_to_string(:nan), do: "NaN"
  def number_to_string(:infinity), do: "Infinity"
  def number_to_string(:neg_infinity), do: "-Infinity"

  def number_to_string(n) when is_integer(n) do
    if Kernel.abs(n) < 1_000_000_000_000_000_000_000,
      do: Integer.to_string(n),
      else: number_to_string(n * 1.0)
  end

  def number_to_string(n) when is_float(n) do
    cond do
      n == 0 -> "0"
      n < 0 -> "-" <> number_to_string(-n)
      true -> format_positive(n)
    end
  end

  defp format_positive(f) do
    {digits, point} = shortest_digits(f)
    k = byte_size(digits)

    cond do
      k <= point and point <= 21 ->
        digits <> String.duplicate("0", point - k)

      0 < point and point <= 21 ->
        binary_part(digits, 0, point) <> "." <> binary_part(digits, point, k - point)

      -6 < point and point <= 0 ->
        "0." <> String.duplicate("0", -point) <> digits

      true ->
        exp = point - 1
        exp_str = if exp >= 0, do: "+#{exp}", else: "#{exp}"

        mantissa =
          if k == 1,
            do: digits,
            else: binary_part(digits, 0, 1) <> "." <> binary_part(digits, 1, k - 1)

        mantissa <> "e" <> exp_str
    end
  end

  # The shortest round-trip digits of a positive float and the decimal point position `n`,
  # so that the value is 0.DIGITS × 10^n.
  defp shortest_digits(f) do
    short = :erlang.float_to_binary(f, [:short])

    {mantissa, exp} =
      case String.split(short, "e", parts: 2) do
        [m, e] -> {m, String.to_integer(e)}
        [m] -> {m, 0}
      end

    {int_part, frac_part} =
      case String.split(mantissa, ".", parts: 2) do
        [i, fr] -> {i, fr}
        [i] -> {i, ""}
      end

    all = int_part <> frac_part
    point = byte_size(int_part) + exp
    trimmed_leading = String.trim_leading(all, "0")
    point = point - (byte_size(all) - byte_size(trimmed_leading))
    {String.trim_trailing(trimmed_leading, "0"), point}
  end

  # ── Equality ─────────────────────────────────────────────────────────────

  @doc """
  ECMA-262 IsLooselyEqual. Two arrays or objects are never equal: every evaluation produces a new
  value, so they can never be the same reference.
  """
  @spec loose_equal?(term(), term()) :: boolean()
  def loose_equal?(nil, nil), do: true
  def loose_equal?(nil, _), do: false
  def loose_equal?(_, nil), do: false

  def loose_equal?(a, b) when is_js_number(a) and is_js_number(b), do: num_equal(a, b)
  def loose_equal?(a, b) when is_binary(a) and is_binary(b), do: a == b
  def loose_equal?(a, b) when is_boolean(a) and is_boolean(b), do: a == b

  def loose_equal?(a, b) when is_js_number(a) and is_binary(b),
    do: num_equal(a, ecma_to_number(b))

  def loose_equal?(a, b) when is_binary(a) and is_js_number(b),
    do: num_equal(ecma_to_number(a), b)

  def loose_equal?(a, b) when is_boolean(a), do: loose_equal?(ecma_to_number(a), b)
  def loose_equal?(a, b) when is_boolean(b), do: loose_equal?(a, ecma_to_number(b))

  def loose_equal?(a, b) do
    a_obj = object?(a)
    b_obj = object?(b)

    cond do
      a_obj and b_obj -> false
      a_obj -> loose_equal?(to_primitive(a), b)
      b_obj -> loose_equal?(a, to_primitive(b))
      true -> false
    end
  end

  defp object?(v), do: is_list(v) or is_map(v)

  # ── JSON ─────────────────────────────────────────────────────────────────

  @doc """
  Converts an evaluated value to plain JSON data the way `JSON.stringify` would: Infinity and NaN
  become null, component instances become `{type, props}`, bindings `{"$binding": name}`.
  """
  def to_json(v) when v in [:infinity, :neg_infinity, :nan], do: nil
  def to_json(v) when is_list(v), do: Enum.map(v, &to_json/1)
  def to_json(%Binding{target: t}), do: %{"$binding" => t}
  def to_json(%Element{} = el), do: Element.summary(el)
  def to_json(%ActionPlan{} = plan), do: ActionPlan.summary(plan)
  def to_json(v) when is_map(v), do: Map.new(v, fn {k, val} -> {k, to_json(val)} end)
  def to_json(v), do: v
end
