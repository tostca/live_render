defmodule LiveRender.OpenUI.Values do
  @moduledoc """
  Converts host data (tool results, persisted state, form input) into OpenUI values: strings,
  numbers in the canonical `LiveRender.OpenUI.JS` form, booleans, nil, lists and string-keyed
  maps. Atom keys and values become strings, tuples become lists, and other structs go through
  their `Jason.Encoder` (so `Date`, `DateTime` and `Decimal` become strings). OpenUI's own
  structs pass through unchanged.
  """

  alias LiveRender.OpenUI.{ActionPlan, Binding, Element, JS}

  @doc "Normalizes a host value. See the module docs."
  @spec from_host(term()) :: term()
  def from_host(nil), do: nil
  def from_host(v) when is_boolean(v) or is_binary(v), do: v
  def from_host(v) when is_integer(v) or is_float(v), do: JS.normalize(v)
  def from_host(v) when v in [:infinity, :neg_infinity, :nan], do: v
  def from_host(v) when is_atom(v), do: Atom.to_string(v)
  def from_host(v) when is_list(v), do: Enum.map(v, &from_host/1)
  def from_host(v) when is_tuple(v), do: v |> Tuple.to_list() |> from_host()
  def from_host(%s{} = v) when s in [Element, ActionPlan, Binding], do: v

  def from_host(%_{} = struct) do
    struct |> Jason.encode!() |> Jason.decode!() |> from_host()
  rescue
    _ -> struct |> Map.from_struct() |> from_host()
  end

  def from_host(map) when is_map(map), do: Map.new(map, fn {k, v} -> {key(k), from_host(v)} end)
  def from_host(other), do: inspect(other)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: to_string(k)
end
