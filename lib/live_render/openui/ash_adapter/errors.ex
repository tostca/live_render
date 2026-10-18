if Code.ensure_loaded?(Ash) do
  defmodule LiveRender.OpenUI.AshAdapter.Errors do
    @moduledoc false
    # Turns Ash errors into short messages that are safe to show to the program and the model.
    # Policy details, stack traces, breadcrumbs and resource internals stay on the server; anything
    # unexpected is logged and reported as "internal error".

    require Logger

    def message(tool, error, stacktrace \\ nil)

    def message(_tool, {:missing_key, keys}, _stacktrace),
      do: "invalid input: " <> Enum.map_join(keys, "; ", &"#{&1}: is required")

    def message(tool, error, stacktrace) do
      class = Ash.Error.to_error_class(error)
      errors = Map.get(class, :errors, [])

      cond do
        match?(%Ash.Error.Forbidden{}, class) ->
          "forbidden"

        Enum.any?(errors, &not_found?/1) ->
          "not found"

        match?(%Ash.Error.Invalid{}, class) ->
          "invalid input: " <> Enum.map_join(errors, "; ", &describe/1)

        true ->
          log(tool, error, stacktrace)
          "internal error"
      end
    rescue
      _ ->
        log(tool, error, stacktrace)
        "internal error"
    end

    defp not_found?(%Ash.Error.Query.NotFound{}), do: true
    defp not_found?(%Ash.Error.Invalid.InvalidPrimaryKey{}), do: true
    defp not_found?(_), do: false

    defp describe(%Ash.Error.Changes.Required{field: field}), do: "#{field}: is required"
    # The host forgot the tenant; do not name the resource module.
    defp describe(%Ash.Error.Invalid.TenantRequired{}), do: "a tenant is required"

    defp describe(%{message: message, vars: vars} = error) when is_binary(message) do
      text = interpolate(message, vars)

      case field(error) do
        nil -> text
        field -> "#{field}: #{text}"
      end
    end

    defp describe(error) do
      case field(error) do
        nil -> own_message(error)
        field -> "#{field}: #{own_message(error)}"
      end
    end

    # Calls the error's own message/1: Exception.message/1 would return an inspected struct when
    # that fails, which is exactly the kind of detail that must not reach the program.
    defp own_message(%module{} = error) do
      %{error | bread_crumbs: []}
      |> module.message()
      |> String.split("\n\nValue:")
      |> hd()
      |> String.trim()
    rescue
      _ -> "is invalid"
    end

    defp field(%{field: field}) when not is_nil(field), do: field
    defp field(%{fields: [_ | _] = fields}), do: Enum.join(fields, ", ")
    defp field(_), do: nil

    defp interpolate(message, vars) do
      Enum.reduce(List.wrap(vars), message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", text(value))
      end)
    end

    defp text(v) when is_binary(v), do: v
    defp text(v) when is_atom(v) or is_number(v), do: to_string(v)
    defp text(v), do: inspect(v)

    defp log(tool, error, nil),
      do: Logger.error("OpenUI tool #{tool.name} failed: #{inspect(error)}")

    defp log(tool, error, stacktrace) do
      Logger.error(
        "OpenUI tool #{tool.name} failed: " <> Exception.format(:error, error, stacktrace)
      )
    end
  end
end
