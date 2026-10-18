if Code.ensure_loaded?(Ash) do
  defmodule LiveRender.OpenUI.AshAdapter.Output do
    @moduledoc false
    # Converts tool results to plain, string-keyed data. A resource record keeps only its public,
    # non-sensitive attributes plus the fields a tool loads explicitly; nothing else in the struct
    # (private attributes, metadata, unloaded fields) is copied.

    alias Ash.Resource.Info
    alias LiveRender.OpenUI.AshAdapter.Tool

    def value(%resource{} = record, %Tool{resource: resource} = tool),
      do: record(record, tool.fields, tool.load)

    def value(value, _tool), do: plain(value)

    defp record(%resource{} = record, fields, load) do
      names = fields || default_fields(resource) ++ load

      Map.new(names, fn name ->
        {Atom.to_string(name), record |> Map.get(name) |> plain()}
      end)
    end

    defp default_fields(resource) do
      for attr <- Info.public_attributes(resource), not attr.sensitive?, do: attr.name
    end

    defp plain(nil), do: nil
    defp plain(v) when is_boolean(v) or is_binary(v) or is_number(v), do: v
    defp plain(v) when is_atom(v), do: Atom.to_string(v)
    defp plain(v) when is_list(v), do: Enum.map(v, &plain/1)
    defp plain(v) when is_tuple(v), do: v |> Tuple.to_list() |> plain()
    defp plain(%Ash.NotLoaded{}), do: nil
    defp plain(%Ash.ForbiddenField{}), do: nil
    defp plain(%Ash.CiString{} = s), do: to_string(s)

    defp plain(%module{} = struct) do
      if Info.resource?(module), do: record(struct, nil, []), else: encoded(struct)
    end

    defp plain(map) when is_map(map),
      do: Map.new(map, fn {k, v} -> {key(k), plain(v)} end)

    defp plain(_other), do: nil

    defp key(k) when is_binary(k), do: k
    defp key(k) when is_atom(k) or is_number(k), do: to_string(k)
    defp key(k), do: inspect(k)

    # Other structs (dates, decimals, ...) go through their JSON encoding. A struct without one is
    # dropped rather than dumped field by field.
    defp encoded(struct) do
      struct |> Jason.encode!() |> Jason.decode!()
    rescue
      _ -> nil
    end
  end
end
