defmodule LiveRender.OpenUI.Store do
  @moduledoc """
  The state store (language.md, section 5.1): a flat map from `$name` (and form names) to values,
  scoped to one rendered program.

  A key still holding its declared default is *pristine*: a later parse may replace that default
  (a default read from a truncated statement while streaming). Values the user or an action
  produced, and persisted values from the host, are never overwritten by defaults. Keys are never
  deleted.
  """

  defstruct values: %{}, pristine: MapSet.new()

  @type t :: %__MODULE__{values: map(), pristine: MapSet.t()}

  @doc "A new empty store."
  def new, do: %__MODULE__{}

  @doc "Reads a key; nil when absent."
  def get(%__MODULE__{values: v}, key), do: Map.get(v, key)

  @doc "True when the key exists."
  def has?(%__MODULE__{values: v}, key), do: Map.has_key?(v, key)

  @doc """
  Writes a key. `pristine: true` marks a restored default (`@Reset`) that a later parse may still
  replace.
  """
  def put(%__MODULE__{} = s, key, value, opts \\ []) do
    pristine =
      if Keyword.get(opts, :pristine, false),
        do: MapSet.put(s.pristine, key),
        else: MapSet.delete(s.pristine, key)

    %{s | values: Map.put(s.values, key, value), pristine: pristine}
  end

  @doc "The whole map."
  def snapshot(%__MODULE__{values: v}), do: v

  @doc """
  Applies persisted host state, then declared defaults where a key has no value yet or still
  holds a pristine default.
  """
  def initialize(%__MODULE__{} = s, defaults, persisted \\ %{}) do
    s =
      Enum.reduce(persisted, s, fn {k, v}, acc ->
        %{acc | values: Map.put(acc.values, k, v), pristine: MapSet.delete(acc.pristine, k)}
      end)

    Enum.reduce(defaults, s, fn {k, v}, acc ->
      cond do
        not Map.has_key?(acc.values, k) ->
          %{acc | values: Map.put(acc.values, k, v), pristine: MapSet.put(acc.pristine, k)}

        MapSet.member?(acc.pristine, k) ->
          %{acc | values: Map.put(acc.values, k, v)}

        true ->
          acc
      end
    end)
  end
end
