defmodule LiveRender.OpenUI.Signature do
  @moduledoc """
  Prompt signatures derived from a library's JSON Schema (prompt.md, section 5.1), and the short
  hint form used in error objects (section 5.3).

      Button(label: string, action?: ActionExpression, variant?: "primary" | "secondary")
      Input(name: string, value?: $binding<string>, rules?: {})
      Percent(part: number, total: number) → string
  """

  alias LiveRender.OpenUI.Library
  alias LiveRender.OpenUI.Library.{Call, Component}

  @doc "The signature of a component, function or action: the given one, or one derived from its schema."
  @spec for(Library.t(), Component.t() | Call.t()) :: String.t()
  def for(_lib, %{signature: sig}) when is_binary(sig), do: sig

  def for(lib, %Component{} = c) do
    params =
      Enum.map(c.params, fn p ->
        type = type_of(lib, p.schema)
        type = if MapSet.member?(c.bindable, p.name), do: "$binding<#{type}>", else: type
        param(p.name, not p.required, type)
      end)

    "#{c.name}(#{Enum.join(params, ", ")})"
  end

  def for(lib, %Call{} = call) do
    params =
      Enum.map(call.params, fn p -> param(p.name, not p.required, type_of(lib, p.schema)) end)

    base = "#{call.name}(#{Enum.join(params, ", ")})"
    if call.returns, do: base <> " → " <> type_of(lib, call.returns), else: base
  end

  defp param(name, true, type), do: "#{name}?: #{type}"
  defp param(name, false, type), do: "#{name}: #{type}"

  @doc "The prompt type of a JSON Schema fragment."
  @spec type_of(Library.t(), term()) :: String.t()
  def type_of(lib, %{"$ref" => "#/$defs/" <> name}) do
    cond do
      name == "ActionExpression" -> "ActionExpression"
      name in ["OpenUrl", "ToAssistant"] or name in lib.action_order -> "@" <> name
      true -> name
    end
  end

  def type_of(lib, %{"anyOf" => options}) when is_list(options), do: union(lib, options)
  def type_of(lib, %{"oneOf" => options}) when is_list(options), do: union(lib, options)

  def type_of(_lib, %{"enum" => values}) when is_list(values),
    do: Enum.map_join(values, " | ", &literal/1)

  def type_of(_lib, %{"const" => value}), do: literal(value)

  def type_of(lib, %{"type" => "array"} = s) do
    case Map.get(s, "items") do
      nil ->
        "any[]"

      items ->
        inner = type_of(lib, items)

        if Map.has_key?(items, "anyOf") or Map.has_key?(items, "oneOf"),
          do: "(#{inner})[]",
          else: "#{inner}[]"
    end
  end

  # Fields print in declaration order, which a `Jason.OrderedObject` keeps; a plain map has none,
  # so its fields are sorted. An object without properties is `object`, as in the reference.
  def type_of(lib, %{"type" => "object"} = s) do
    required = Map.get(s, "required", [])

    case object_fields(Map.get(s, "properties")) do
      [] ->
        "object"

      fields ->
        fields
        |> Enum.map(fn {name, sub} -> param(name, name not in required, type_of(lib, sub)) end)
        |> then(&"{#{Enum.join(&1, ", ")}}")
    end
  end

  def type_of(_lib, %{"type" => "integer"}), do: "number"
  def type_of(_lib, %{"type" => t}) when t in ["string", "number", "boolean"], do: t
  def type_of(_lib, _), do: "any"

  defp object_fields(%Jason.OrderedObject{values: values}), do: values
  defp object_fields(map) when is_map(map), do: Enum.sort_by(map, &elem(&1, 0))
  defp object_fields(_), do: []

  defp union(lib, options), do: Enum.map_join(options, " | ", &type_of(lib, &1))

  defp literal(v) when is_binary(v), do: ~s("#{v}")
  defp literal(v), do: Jason.encode!(v)

  @doc """
  The short hint of an error object: `Signature: Name(a*, b) — * marks required`.
  """
  @spec hint(String.t(), [Library.Param.t()]) :: String.t()
  def hint(name, params) do
    names =
      Enum.map_join(params, ", ", fn p -> if p.required, do: p.name <> "*", else: p.name end)

    "Signature: #{name}(#{names}) — * marks required"
  end

  @doc """
  A typed signature used inside validation messages: `Header(title*: string, variant: "a"|"b")`.
  """
  @spec typed(String.t(), [Library.Param.t()]) :: String.t()
  def typed(name, params) do
    rendered =
      Enum.map_join(params, ", ", fn p ->
        marked = if p.required, do: p.name <> "*", else: p.name

        case short_type(p.schema) do
          nil -> marked
          t -> "#{marked}: #{t}"
        end
      end)

    "#{name}(#{rendered})"
  end

  defp short_type(%{"$ref" => ref}) when is_binary(ref),
    do: ref |> String.split("/") |> List.last()

  defp short_type(%{"enum" => values}) when is_list(values),
    do: Enum.map_join(values, "|", &Jason.encode!/1)

  defp short_type(%{"const" => v}), do: Jason.encode!(v)
  defp short_type(%{"type" => "integer"}), do: "number"
  defp short_type(%{"type" => t}) when is_binary(t), do: t
  defp short_type(_), do: nil
end
