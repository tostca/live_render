defmodule LiveRender.OpenUI.Rules do
  @moduledoc """
  Validation rules for input components (language.md, section 5.4):

      { required: true, email: true, url: true, numeric: true,
        minLength: 3, maxLength: 80, min: 0, max: 10, pattern: "^[A-Z]{2}\\\\d{3}$" }

  Every rule except `required` skips empty values (null, `""`, an empty array, an object with no
  keys). The first failing rule gives the field its error; rules are checked in the order above.
  A rule set to `false` or null is off.
  """

  alias LiveRender.OpenUI.{Builtins, JS}

  @order ~w(required email url numeric minLength maxLength min max pattern)
  @max_pattern 512
  @max_value 10_000

  @doc "Returns nil when `value` passes every rule, or the first error message."
  @spec validate(term(), map() | nil) :: String.t() | nil
  def validate(value, rules) when is_map(rules) do
    value = unwrap(value)

    rules
    |> Enum.reject(fn {_k, v} -> v in [false, nil] end)
    |> Enum.sort_by(fn {k, _} -> Enum.find_index(@order, &(&1 == k)) || length(@order) end)
    |> Enum.find_value(fn {rule, arg} -> check(rule, value, arg) end)
  end

  def validate(_value, _rules), do: nil

  # Form state stores {value, componentType}; validation reads the value.
  defp unwrap(%{"value" => v, "componentType" => _}), do: v
  defp unwrap(v), do: v

  @doc "True for null, `\"\"`, an empty array or an object with no keys."
  def empty?(nil), do: true
  def empty?(""), do: true
  def empty?([]), do: true
  def empty?(%{"value" => v, "componentType" => _}), do: empty?(v)
  def empty?(map) when is_map(map) and not is_struct(map), do: map_size(map) == 0
  def empty?(_), do: false

  defp check("required", value, _arg) do
    cond do
      empty?(value) ->
        "This field is required"

      is_map(value) and not is_struct(value) and Enum.all?(value, fn {_, v} -> is_boolean(v) end) and
          not Enum.any?(value, fn {_, v} -> v end) ->
        "At least one option is required"

      true ->
        nil
    end
  end

  defp check(_rule, value, _arg) when value in [nil, "", []], do: nil

  defp check(rule, value, arg) do
    if empty?(value), do: nil, else: check_present(rule, value, arg)
  end

  defp check_present("email", value, _arg) do
    if is_binary(value) and Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/u, value),
      do: nil,
      else: "Please enter a valid email"
  end

  defp check_present("url", value, _arg) do
    if is_binary(value) and absolute_url?(value), do: nil, else: "Please enter a valid URL"
  end

  defp check_present("numeric", value, _arg) do
    cond do
      is_number(value) -> nil
      is_binary(value) and JS.trim(value) != "" and JS.parse_float(value) != :nan -> nil
      true -> "Must be a number"
    end
  end

  defp check_present("min", value, arg) do
    case number_of(value) do
      :nan ->
        nil

      n ->
        if JS.less_than(n, JS.to_number(arg)),
          do: "Must be at least #{JS.to_string_value(arg)}",
          else: nil
    end
  end

  defp check_present("max", value, arg) do
    case number_of(value) do
      :nan ->
        nil

      n ->
        if JS.less_than(JS.to_number(arg), n),
          do: "Must be no more than #{JS.to_string_value(arg)}",
          else: nil
    end
  end

  defp check_present("minLength", value, arg) when is_binary(value) do
    if Builtins.utf16_length(value) >= JS.to_number(arg),
      do: nil,
      else: "Must be at least #{JS.to_string_value(arg)} characters"
  end

  defp check_present("maxLength", value, arg) when is_binary(value) do
    if Builtins.utf16_length(value) <= JS.to_number(arg),
      do: nil,
      else: "Must be no more than #{JS.to_string_value(arg)} characters"
  end

  defp check_present("pattern", value, arg) when is_binary(value) and is_binary(arg) do
    if pattern_match?(arg, value), do: nil, else: "Invalid format"
  end

  # Unknown rules and rules that do not apply to the value's type pass.
  defp check_present(_rule, _value, _arg), do: nil

  defp number_of(v) when is_number(v), do: v
  defp number_of(v), do: JS.parse_float(JS.to_string_value(v))

  defp absolute_url?(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host}}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  # A pattern that does not compile passes, as in the reference client. Patterns and values are
  # capped, and PCRE's match limits bound backtracking.
  defp pattern_match?(pattern, value) do
    if byte_size(pattern) > @max_pattern or byte_size(value) > @max_value do
      true
    else
      case :re.compile(pattern, [:unicode]) do
        {:ok, re} ->
          case :re.run(value, re, [
                 {:match_limit, 100_000},
                 {:match_limit_recursion, 5_000},
                 {:capture, :none}
               ]) do
            :match -> true
            :nomatch -> false
            {:error, _} -> true
          end

        {:error, _} ->
          true
      end
    end
  end
end
