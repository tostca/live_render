if Code.ensure_loaded?(Ash) do
  defmodule LiveRender.OpenUI.AshAdapter.Inputs do
    @moduledoc false
    # What a program may pass to a tool: the action's public arguments and public accepted
    # attributes, the primary key for update/destroy, and limit/offset for paginated reads.
    # Keys are matched against names read from the resource, so program strings never become
    # atoms.

    alias Ash.Resource.Info
    alias Ash.Type.NewType
    alias LiveRender.OpenUI.AshAdapter.Tool

    # [{name, :argument | :attribute, definition}] in declaration order.
    def accepted(%Tool{} = tool) do
      action = Info.action(tool.resource, tool.action)
      tenant_attribute = Info.multitenancy_attribute(tool.resource)

      arguments =
        for arg <- action.arguments, arg.public?, do: {arg.name, :argument, arg}

      attributes =
        for name <- Map.get(action, :accept) || [],
            name != tenant_attribute,
            %{public?: true} = attr <- [Info.attribute(tool.resource, name)],
            do: {name, :attribute, attr}

      Enum.uniq_by(arguments ++ attributes, &elem(&1, 0))
    end

    def input(%Tool{} = tool, args) do
      for {name, _kind, _def} <- accepted(tool),
          {:ok, value} <- [fetch(args, name)],
          into: %{},
          do: {name, value}
    end

    def primary_key(%Tool{} = tool, args) do
      keys = Info.primary_key(tool.resource)

      found =
        for key <- keys, {:ok, v} <- [fetch(args, key)], not is_nil(v), into: %{}, do: {key, v}

      case keys -- Map.keys(found) do
        [] -> {:ok, found}
        missing -> {:error, missing}
      end
    end

    def page(%Tool{type: :read, pagination: true, limit: max}, args) do
      limit =
        case fetch(args, :limit) do
          {:ok, n} when is_integer(n) and n > 0 -> min(n, max)
          _ -> max
        end

      offset =
        case fetch(args, :offset) do
          {:ok, n} when is_integer(n) and n >= 0 -> n
          _ -> 0
        end

      {limit, offset}
    end

    def page(%Tool{limit: max}, _args), do: {max, 0}

    defp fetch(args, name) do
      key = Atom.to_string(name)

      cond do
        Map.has_key?(args, key) -> {:ok, Map.get(args, key)}
        Map.has_key?(args, name) -> {:ok, Map.get(args, name)}
        true -> :error
      end
    end

    def json_schema(%Tool{} = tool) do
      action = Info.action(tool.resource, tool.action)

      key_fields =
        if tool.type in [:update, :destroy] do
          for key <- Info.primary_key(tool.resource) do
            attr = Info.attribute(tool.resource, key)
            {key, schema(attr.type, attr.constraints, "The #{key} of the record"), true}
          end
        else
          []
        end

      input_fields =
        for {name, kind, definition} <- accepted(tool) do
          {name, schema(definition.type, definition.constraints, definition.description),
           required?(kind, definition, action)}
        end

      fields = key_fields ++ input_fields ++ page_fields(tool)

      properties = Map.new(fields, fn {name, s, _} -> {Atom.to_string(name), s} end)
      required = for {name, _, true} <- fields, do: Atom.to_string(name)

      %{"type" => "object", "properties" => properties, "additionalProperties" => false}
      |> put_unless_empty("required", Enum.uniq(required))
    end

    defp page_fields(%Tool{type: :read, pagination: true, limit: max}) do
      [
        {:limit, %{"type" => "integer", "minimum" => 1, "maximum" => max}, false},
        {:offset, %{"type" => "integer", "minimum" => 0}, false}
      ]
    end

    defp page_fields(_tool), do: []

    defp required?(:argument, arg, _action), do: arg.allow_nil? == false and is_nil(arg.default)

    defp required?(:attribute, attr, action) do
      attr.name in (Map.get(action, :require_attributes) || []) or
        (action.type == :create and attr.allow_nil? == false and is_nil(attr.default) and
           not attr.generated? and attr.name not in (Map.get(action, :allow_nil_input) || []))
    end

    # A JSON Schema for an Ash type. Unknown types get an empty schema (any value).
    def schema(type, constraints, description \\ nil) do
      type |> type_schema(constraints || []) |> put_unless_empty("description", description)
    end

    defp type_schema({:array, inner}, constraints) do
      %{"type" => "array", "items" => type_schema(inner, constraints[:items] || [])}
      |> put_unless_empty("minItems", constraints[:min_length])
      |> put_unless_empty("maxItems", constraints[:max_length])
    end

    defp type_schema(type, constraints) do
      type = Ash.Type.get_type(type)

      cond do
        not is_atom(type) ->
          %{}

        NewType.new_type?(type) ->
          type_schema(
            NewType.subtype_of(type),
            NewType.constraints(type, constraints)
          )

        Spark.implements_behaviour?(type, Ash.Type.Enum) ->
          %{"type" => "string", "enum" => Enum.map(type.values(), &to_string/1)}

        true ->
          builtin(type, constraints)
      end
    end

    defp builtin(type, c) when type in [Ash.Type.String, Ash.Type.CiString] do
      %{"type" => "string"}
      |> put_unless_empty("minLength", c[:min_length])
      |> put_unless_empty("maxLength", c[:max_length])
    end

    defp builtin(Ash.Type.Atom, c) do
      %{"type" => "string"}
      |> put_unless_empty("enum", c[:one_of] && Enum.map(c[:one_of], &to_string/1))
    end

    defp builtin(Ash.Type.Integer, c), do: range(%{"type" => "integer"}, c)

    defp builtin(type, c) when type in [Ash.Type.Float, Ash.Type.Decimal],
      do: range(%{"type" => "number"}, c)

    defp builtin(Ash.Type.Boolean, _c), do: %{"type" => "boolean"}
    defp builtin(Ash.Type.Date, _c), do: %{"type" => "string", "format" => "date"}
    defp builtin(Ash.Type.Time, _c), do: %{"type" => "string", "format" => "time"}

    defp builtin(type, _c)
         when type in [
                Ash.Type.UtcDatetime,
                Ash.Type.UtcDatetimeUsec,
                Ash.Type.DateTime,
                Ash.Type.NaiveDatetime
              ],
         do: %{"type" => "string", "format" => "date-time"}

    defp builtin(type, _c) when type in [Ash.Type.UUID, Ash.Type.UUIDv7],
      do: %{"type" => "string", "format" => "uuid"}

    defp builtin(type, _c) when type in [Ash.Type.Map, Ash.Type.Keyword, Ash.Type.Struct],
      do: %{"type" => "object"}

    defp builtin(_type, _c), do: %{}

    defp range(schema, c) do
      schema
      |> put_unless_empty("minimum", number(c[:min]))
      |> put_unless_empty("maximum", number(c[:max]))
      |> put_unless_empty("exclusiveMinimum", number(c[:greater_than]))
      |> put_unless_empty("exclusiveMaximum", number(c[:less_than]))
    end

    defp number(nil), do: nil
    defp number(n) when is_number(n), do: n
    defp number(%Decimal{} = d), do: Decimal.to_float(d)
    defp number(_), do: nil

    defp put_unless_empty(map, _key, nil), do: map
    defp put_unless_empty(map, _key, []), do: map
    defp put_unless_empty(map, key, value), do: Map.put(map, key, value)
  end
end
