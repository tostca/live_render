defmodule LiveRender.OpenUI.Builtins do
  @moduledoc """
  The built-in functions and actions of OpenUI 1.0 (language.md, sections 3.4 and 6.3).

  Built-ins coerce their arguments with `toNumber` and friends, so the runtime maps them by
  position and calls them without schema validation. `@Each`, `Action`, `@Run`, `@Set` and
  `@Reset` are *lazy*: they receive their arguments unevaluated.
  """

  alias LiveRender.OpenUI.{Collation, JS}

  @functions [
    {"Count", ["array"], "Returns array length", "Count(array: any[]) → number"},
    {"First", ["array"], "Returns first element of array", "First(array: any[]) → any"},
    {"Last", ["array"], "Returns last element of array", "Last(array: any[]) → any"},
    {"Sum", ["numbers"], "Sum of numeric array", "Sum(numbers: number[]) → number"},
    {"Avg", ["numbers"], "Average of numeric array", "Avg(numbers: number[]) → number"},
    {"Min", ["numbers"], "Minimum value in array", "Min(numbers: number[]) → number"},
    {"Max", ["numbers"], "Maximum value in array", "Max(numbers: number[]) → number"},
    {"Sort", ["array", "field", "direction"],
     ~s|Sort array by field. Direction: "asc" (default) or "desc"|,
     ~s|Sort(array: any[], field: string, direction?: "asc" \| "desc") → any[]|},
    {"Filter", ["array", "field", "operator", "value"], "Filter array by field value",
     ~s|Filter(array: any[], field: string, operator: "==" \| "!=" \| ">" \| "<" \| ">=" \| "<=" \| "contains", value: any) → any[]|},
    {"Round", ["number", "decimals"], "Round to N decimal places (default 0)",
     "Round(number: number, decimals?: number) → number"},
    {"Abs", ["number"], "Absolute value", "Abs(number: number) → number"},
    {"Floor", ["number"], "Round down to nearest integer", "Floor(number: number) → number"},
    {"Ceil", ["number"], "Round up to nearest integer", "Ceil(number: number) → number"},
    {"Each", ["array", "varName", "template"],
     "Evaluate template for each element. varName is the loop variable — use it ONLY inside the template expression (inline). Do NOT create a separate statement for the template.",
     "Each(array: any[], varName: string, template: any)"}
  ]

  @steps [
    {"Run", ["ref"],
     "Execute a Mutation or re-fetch a Query (ref must be a declared Query/Mutation)",
     "Run(ref: Query | Mutation)"},
    {"ToAssistant", ["message", "context"],
     ~s|Send a message to the assistant (for conversational buttons like "Tell me more", "Explain this"). The optional context is any value (object, array, string, number) passed to the assistant as hidden data, e.g. @ToAssistant("Show details", {orderId: 42})|,
     "ToAssistant(message: string, context?: any)"},
    {"OpenUrl", ["url"], "Navigate to a URL", "OpenUrl(url: string)"},
    {"Set", ["variable", "value"], "Set a $variable to a specific value",
     "Set(variable: $variable, value: any)"},
    {"Reset", ["variable"],
     ~s|Reset $variables to their declared defaults; pass several to reset each (e.g. @Reset($title, $priority) restores $title="" and $priority="medium")|,
     "Reset(variable: $variable)"}
  ]

  @function_names Enum.map(@functions, &elem(&1, 0))
  @step_names Enum.map(@steps, &elem(&1, 0))
  @lazy ["Each", "Action", "Run", "Set", "Reset"]

  @doc "Built-in function names, in prompt order."
  def function_names, do: @function_names

  @doc "Built-in action names, in prompt order."
  def step_names, do: @step_names

  @doc "`[{name, params, description, signature}]` for the built-in functions."
  def functions, do: @functions

  @doc "`[{name, params, description, signature}]` for the built-in actions."
  def steps, do: @steps

  @doc "True for a built-in function, a built-in action or `Action`."
  def builtin?(name), do: name in @function_names or name in @step_names or name == "Action"

  @doc "True for a built-in function."
  def function?(name), do: name in @function_names

  @doc "True for a built-in action or `Action`."
  def step?(name), do: name in @step_names or name == "Action"

  @doc "True for a built-in whose arguments stay unevaluated."
  def lazy?(name), do: name in @lazy

  @doc "Names reserved by the language: built-ins, `Query`, `Mutation`, `Action`."
  def reserved?(name), do: builtin?(name) or name in ["Query", "Mutation"]

  @doc "Positional parameter names of a built-in."
  def params("Action"), do: ["steps"]

  def params(name) do
    case List.keyfind(@functions, name, 0) || List.keyfind(@steps, name, 0) do
      {_, params, _, _} -> params
      nil -> []
    end
  end

  # ── Implementations ──────────────────────────────────────────────────────

  @doc "Calls an eager built-in function with its arguments keyed by parameter name."
  @spec call(String.t(), map()) :: term()
  def call("Count", %{"array" => a}) when is_list(a), do: length(a)
  def call("Count", _), do: 0
  def call("First", %{"array" => [first | _]}), do: first
  def call("First", _), do: nil
  def call("Last", %{"array" => [_ | _] = a}), do: List.last(a)
  def call("Last", _), do: nil
  def call("Sum", %{"numbers" => a}) when is_list(a), do: sum(a)
  def call("Sum", _), do: 0
  def call("Avg", %{"numbers" => [_ | _] = a}), do: JS.divide(sum(a), length(a))
  def call("Avg", _), do: 0
  def call("Min", %{"numbers" => [first | _] = a}), do: extreme(a, first, &JS.less_than/2)
  def call("Min", _), do: 0
  def call("Max", %{"numbers" => [first | _] = a}), do: extreme(a, first, &JS.less_than(&2, &1))
  def call("Max", _), do: 0

  def call("Sort", %{"array" => a} = args) when is_list(a) do
    field = args |> Map.get("field") |> field_string()
    desc? = args |> Map.get("direction") |> field_string() == "desc"

    Enum.sort(a, fn x, y ->
      c = sort_compare(read_field(x, field), read_field(y, field))
      c = if desc?, do: -c, else: c
      c <= 0
    end)
  end

  def call("Sort", args), do: Map.get(args, "array")

  def call("Filter", %{"array" => a} = args) when is_list(a) do
    field = args |> Map.get("field") |> field_string()

    op =
      args |> Map.get("operator") |> then(&if(is_nil(&1), do: "==", else: JS.to_string_value(&1)))

    value = Map.get(args, "value")
    Enum.filter(a, fn item -> filter_match?(op, read_field(item, field), value) end)
  end

  def call("Filter", _), do: []

  def call("Round", args) do
    num = JS.to_number(Map.get(args, "number"))
    d = if is_nil(Map.get(args, "decimals")), do: 0, else: JS.to_number(args["decimals"])
    factor = JS.pow(10, d)
    JS.divide(JS.round(JS.mul(num, factor)), factor)
  end

  def call("Abs", args), do: args |> Map.get("number") |> JS.to_number() |> JS.abs_value()
  def call("Floor", args), do: args |> Map.get("number") |> JS.to_number() |> JS.floor()
  def call("Ceil", args), do: args |> Map.get("number") |> JS.to_number() |> JS.ceil()

  defp sum(list), do: Enum.reduce(list, 0, fn v, acc -> JS.add(acc, JS.to_number(v)) end)

  defp extreme([_ | _] = list, first, better?) do
    Enum.reduce(list, JS.to_number(first), fn v, acc ->
      n = JS.to_number(v)

      cond do
        n == :nan or acc == :nan -> :nan
        better?.(n, acc) -> n
        true -> acc
      end
    end)
  end

  defp field_string(nil), do: ""
  defp field_string(v), do: JS.to_string_value(v)

  @doc """
  Reads a field path such as `"customer.name"` from a value. An empty path returns the value
  itself; a missing field gives nil.
  """
  def read_field(value, ""), do: value
  def read_field(nil, _path), do: nil

  def read_field(value, path) do
    path
    |> String.split(".")
    |> Enum.reduce_while(value, fn key, acc ->
      case get_field(acc, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp get_field(map, key) when is_map(map) and not is_struct(map), do: Map.get(map, key)
  defp get_field(list, "length") when is_list(list), do: length(list)

  defp get_field(list, key) when is_list(list) do
    case Integer.parse(key) do
      {i, ""} when i >= 0 -> Enum.at(list, i)
      _ -> nil
    end
  end

  defp get_field(str, "length") when is_binary(str), do: utf16_length(str)
  defp get_field(_, _), do: nil

  @doc false
  def utf16_length(str) do
    str
    |> String.to_charlist()
    |> Enum.reduce(0, fn cp, n -> if cp > 0xFFFF, do: n + 2, else: n + 1 end)
  rescue
    _ -> byte_size(str)
  end

  defp numeric?(v) when is_integer(v) or is_float(v) or v in [:infinity, :neg_infinity], do: true
  defp numeric?(v) when is_binary(v) and v != "", do: JS.ecma_to_number(v) != :nan
  defp numeric?(_), do: false

  defp sort_compare(a, b) do
    if numeric?(a) and numeric?(b) do
      na = JS.to_number(a)
      nb = JS.to_number(b)

      cond do
        JS.less_than(na, nb) -> -1
        JS.less_than(nb, na) -> 1
        true -> 0
      end
    else
      Collation.compare(locale_string(a), locale_string(b))
    end
  end

  defp locale_string(nil), do: ""
  defp locale_string(v), do: JS.to_string_value(v)

  defp filter_match?("==", v, value), do: JS.loose_equal?(v, value)
  defp filter_match?("!=", v, value), do: not JS.loose_equal?(v, value)
  defp filter_match?(">", v, value), do: JS.less_than(JS.to_number(value), JS.to_number(v))
  defp filter_match?("<", v, value), do: JS.less_than(JS.to_number(v), JS.to_number(value))

  defp filter_match?(">=", v, value) do
    a = JS.to_number(v)
    b = JS.to_number(value)
    JS.less_than(b, a) or JS.num_equal(a, b)
  end

  defp filter_match?("<=", v, value) do
    a = JS.to_number(v)
    b = JS.to_number(value)
    JS.less_than(a, b) or JS.num_equal(a, b)
  end

  defp filter_match?("contains", v, value) do
    String.contains?(locale_string(v), locale_string(value))
  end

  defp filter_match?(_unknown, _v, _value), do: false
end
