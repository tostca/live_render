defmodule LiveRender.OpenUI.Validation do
  @moduledoc """
  Checks materialized values against JSON Schema fragments and applies the recovery rules of
  language.md, sections 8.2 and 8.4.

  `check/5` returns `{result, ctx}` where `result` is the (possibly cleaned) value, `:invalid`
  after reporting a violation, or the value itself. Every violation is reported. Then one rule
  applies at each edge (`resolve_invalid/2`): a schema default substitutes; a required edge makes
  the parent invalid; an optional edge is removed (`:omit`). Array items are always removed.

  `ctx` is any map with `:errors`, `:partial`, `:lib` and `:current` keys (the materializer's
  context, or a small one at runtime).
  """

  alias LiveRender.OpenUI.{ActionPlan, Binding, Builtins, Element, Error, Library, Signature}

  @doc "The edge rule for an invalid value: default, else `:invalid` if required, else `:omit`."
  def resolve_invalid(_required, {:ok, default}), do: default
  def resolve_invalid(true, :none), do: :invalid
  def resolve_invalid(false, :none), do: :omit

  @doc "Validates `value` against `schema`. See the module docs."
  def check(value, schema, component, path, ctx)

  def check(value, schema, _c, _p, ctx) when not is_map(schema), do: {value, ctx}
  def check(nil, _schema, _c, _p, ctx), do: {nil, ctx}
  # Runtime expressions resolve later.
  def check(value, _schema, _c, _p, ctx) when is_tuple(value), do: {value, ctx}

  def check(%Element{} = el, schema, component, path, ctx) do
    if composite?(schema) do
      {el, ctx}
    else
      case schema do
        %{"type" => t} when is_binary(t) ->
          {:invalid,
           issue(ctx, component, path, {:type_mismatch, t, ~s(component "#{el.type_name}")})}

        %{"enum" => _} ->
          {:invalid,
           issue(
             ctx,
             component,
             path,
             {:type_mismatch, "a literal value", ~s(component "#{el.type_name}")}
           )}

        %{"const" => _} ->
          {:invalid,
           issue(
             ctx,
             component,
             path,
             {:type_mismatch, "a literal value", ~s(component "#{el.type_name}")}
           )}

        _ ->
          {el, ctx}
      end
    end
  end

  def check(value, schema, component, path, ctx) do
    cond do
      composite?(schema) ->
        if only_component_slot?(schema, ctx) do
          expected = schema |> slot_ref_names() |> Enum.join(" | ")
          {:invalid, issue(ctx, component, path, {:type_mismatch, expected, slot_actual(value)})}
        else
          {value, ctx}
        end

      schema["type"] == "object" ->
        check_object(value, schema, component, path, ctx)

      schema["type"] == "array" ->
        check_array(value, schema, component, path, ctx)

      true ->
        check_leaf(value, schema, component, path, ctx)
    end
  end

  defp composite?(s),
    do:
      Map.has_key?(s, "$ref") or Map.has_key?(s, "anyOf") or Map.has_key?(s, "oneOf") or
        Map.has_key?(s, "allOf")

  defp slot_ref_names(s) do
    options = Map.get(s, "anyOf") || Map.get(s, "oneOf") || [s]
    Enum.map(options, &ref_name/1)
  end

  defp ref_name(%{"$ref" => ref}) when is_binary(ref), do: ref |> String.split("/") |> List.last()
  defp ref_name(_), do: nil

  defp only_component_slot?(_s, %{lib: nil}), do: false

  defp only_component_slot?(s, %{lib: lib}) do
    names = slot_ref_names(s)
    names != [] and Enum.all?(names, &(&1 != nil and Library.component?(lib, &1)))
  end

  defp slot_actual(v) when is_list(v), do: "array"
  defp slot_actual(v) when is_map(v), do: "plain object"
  defp slot_actual(v), do: js_typeof(v)

  defp check_object(value, s, component, path, ctx) do
    if not is_map(value) or is_struct(value, Element) do
      {:invalid, issue(ctx, component, path, {:type_mismatch, "object", js_type(value)})}
    else
      do_check_object(value, s, component, path, ctx)
    end
  end

  defp do_check_object(%s{} = value, _schema, _c, _p, ctx) when s in [ActionPlan, Binding],
    do: {value, ctx}

  defp do_check_object(obj, s, component, path, ctx) do
    props = if is_map(s["properties"]), do: s["properties"], else: %{}
    required = if is_list(s["required"]), do: s["required"], else: []
    shape = %{props: props, required: required, component: component, path: path}

    # Structural checks wait for complete input.
    acc = {obj, false, ctx}

    acc =
      if ctx.partial, do: acc, else: Enum.reduce(required, acc, &check_required(&1, &2, shape))

    {obj, invalid, ctx} =
      props
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(acc, &check_property(&1, &2, shape))

    if invalid, do: {:invalid, ctx}, else: {obj, ctx}
  end

  # An absent or null required key fills silently from its schema default.
  defp check_required(key, {obj, invalid, ctx}, shape) do
    present = Map.has_key?(obj, key)

    cond do
      present and obj[key] != nil ->
        {obj, invalid, ctx}

      match?({:ok, _}, schema_default(shape.props[key])) ->
        {:ok, d} = schema_default(shape.props[key])
        {Map.put(obj, key, d), invalid, ctx}

      true ->
        code = if present, do: :null_required, else: :missing_required
        {obj, true, issue(ctx, shape.component, "#{shape.path}/#{key}", {code, nil})}
    end
  end

  defp check_property({key, sub}, {obj, invalid, ctx} = acc, shape) do
    if Map.has_key?(obj, key) do
      {next, ctx} = check(obj[key], sub, shape.component, "#{shape.path}/#{key}", ctx)
      next = resolve_edge(next, key in shape.required, sub)

      case next do
        :invalid -> {obj, true, ctx}
        :omit -> {Map.delete(obj, key), invalid, ctx}
        v -> {Map.put(obj, key, v), invalid, ctx}
      end
    else
      acc
    end
  end

  defp resolve_edge(:invalid, required, sub), do: resolve_invalid(required, schema_default(sub))
  defp resolve_edge(value, _required, _sub), do: value

  defp check_array(value, _s, component, path, ctx) when not is_list(value),
    do: {:invalid, issue(ctx, component, path, {:type_mismatch, "array", js_type(value)})}

  defp check_array(value, %{"items" => items}, component, path, ctx) when is_map(items) do
    {kept, ctx} =
      value
      |> Enum.with_index()
      |> Enum.reduce({[], ctx}, fn {item, i}, {acc, c} ->
        keep_item(check(item, items, component, "#{path}/#{i}", c), acc)
      end)

    {Enum.reverse(kept), ctx}
  end

  defp check_array(value, _s, _component, _path, ctx), do: {value, ctx}

  # Invalid array items are always left out.
  defp keep_item({result, ctx}, acc) when result in [:invalid, :omit], do: {acc, ctx}
  defp keep_item({value, ctx}, acc), do: {[value | acc], ctx}

  # Enum membership waits for complete input; scalar type checks run while streaming.
  defp check_leaf(value, s, component, path, ctx) do
    cond do
      is_list(s["enum"]) ->
        if ctx.partial, do: {value, ctx}, else: check_enum(value, s["enum"], component, path, ctx)

      Map.has_key?(s, "const") ->
        if ctx.partial,
          do: {value, ctx},
          else: check_enum(value, [s["const"]], component, path, ctx)

      true ->
        case expected_type(s["type"]) do
          nil -> {value, ctx}
          type -> check_type(value, type, component, path, ctx)
        end
    end
  end

  defp check_enum(value, values, component, path, ctx) do
    scalar? = js_typeof(value) in ["string", "number", "boolean"]

    if not scalar? or Enum.any?(values, &(&1 == value)) do
      {value, ctx}
    else
      expected = "one of [" <> Enum.map_join(values, ", ", &Jason.encode!/1) <> "]"
      {:invalid, issue(ctx, component, path, {:type_mismatch, expected, json(value)})}
    end
  end

  defp check_type(value, type, component, path, ctx) do
    if js_typeof(value) == type,
      do: {value, ctx},
      else: {:invalid, issue(ctx, component, path, {:type_mismatch, type, js_type(value)})}
  end

  defp expected_type("string"), do: "string"
  defp expected_type("number"), do: "number"
  defp expected_type("integer"), do: "number"
  defp expected_type("boolean"), do: "boolean"
  defp expected_type(_), do: nil

  defp json(v) do
    Jason.encode!(LiveRender.OpenUI.JS.to_json(v))
  rescue
    _ -> inspect(v)
  end

  @doc "JavaScript `typeof` for OpenUI values."
  def js_typeof(v) when is_binary(v), do: "string"
  def js_typeof(v) when is_boolean(v), do: "boolean"
  def js_typeof(nil), do: "object"
  def js_typeof(v) when is_number(v) or v in [:infinity, :neg_infinity, :nan], do: "number"
  def js_typeof(_), do: "object"

  defp js_type(v) when is_list(v), do: "array"
  defp js_type(v), do: js_typeof(v)

  @doc "The `default` of a schema fragment, as `{:ok, value}` or `:none`."
  def schema_default(%{"default" => d}), do: {:ok, d}
  def schema_default(_), do: :none

  # ── Issues ───────────────────────────────────────────────────────────────

  @doc """
  Appends a parser error to `ctx.errors` (kept in reverse order) and returns the context.

  Issues: `{:type_mismatch, expected, actual}`, `{:missing_required, signature}`,
  `{:null_required, signature}`, `{:unknown_component, available}`, `:inline_reserved`,
  `{:excess_args, declared, got}`, `:unknown_function`, `{:no_root, reason}`.
  """
  def issue(ctx, component, path, issue) do
    error = %Error{
      source: :parser,
      code: code(issue),
      component: component,
      path: path,
      message: message(component, path, issue),
      statement_id: ctx.current,
      hint: hint(ctx, component, issue),
      severity: if(match?({:no_root, :fallback}, issue), do: :warning)
    }

    %{ctx | errors: [error | ctx.errors]}
  end

  defp code({:type_mismatch, _, _}), do: "type-mismatch"
  defp code({:missing_required, _}), do: "missing-required"
  defp code({:null_required, _}), do: "null-required"
  defp code({:unknown_component, _}), do: "unknown-component"
  defp code(:inline_reserved), do: "inline-reserved"
  defp code({:excess_args, _, _}), do: "excess-args"
  defp code(:unknown_function), do: "unknown-function"
  defp code({:no_root, _}), do: "no-root"

  defp message(_c, path, {:type_mismatch, expected, actual}),
    do: ~s(field "#{path}" expects #{expected} but got #{actual})

  defp message(_c, path, {:missing_required, sig}),
    do: ~s(missing required field "#{path}") <> signature_suffix(sig)

  defp message(_c, path, {:null_required, sig}),
    do: ~s(required field "#{path}" cannot be null) <> signature_suffix(sig)

  defp message(c, _path, {:unknown_component, available}) do
    base = ~s(Unknown component "#{c}" — not found in catalog or builtins)

    case available do
      [_ | _] -> base <> ". Available components: " <> Enum.join(available, ", ")
      _ -> base
    end
  end

  defp message(c, _path, :inline_reserved),
    do: "#{c}() must be declared as a top-level statement, not used inline as a value"

  defp message(c, _path, {:excess_args, declared, got}),
    do: "#{c} takes #{declared} arg(s), got #{got} (#{got - declared} excess dropped)"

  defp message(c, _path, :unknown_function),
    do: ~s(Unknown function "@#{c}": not a built-in or action step. The call evaluates to null)

  defp message(_c, _path, {:no_root, :not_component}), do: "root does not evaluate to a component"

  defp message(c, _path, {:no_root, :fallback}),
    do: "No root statement. Rendering the first statement that calls the root component #{c}"

  defp message("", _path, {:no_root, :missing}), do: "No root statement"

  defp message(c, _path, {:no_root, :missing}),
    do: "No root statement, and no statement calls the root component #{c}"

  defp signature_suffix(nil), do: ""
  defp signature_suffix(sig), do: " — signature: " <> sig

  defp hint(%{lib: nil}, _c, _issue), do: nil

  defp hint(%{lib: lib}, _c, {:unknown_component, _}) do
    case Library.component_names(lib) do
      [] -> nil
      names -> "Available components: " <> Enum.join(names, ", ")
    end
  end

  defp hint(%{lib: lib}, c, {code, _}) when code in [:missing_required, :null_required] do
    case Library.get_component(lib, c) || Library.get_call(lib, c) do
      %{params: params} -> Signature.hint(c, params)
      nil -> nil
    end
  end

  defp hint(_ctx, c, :inline_reserved), do: "Declare as a top-level statement: myVar = #{c}(...)"

  defp hint(%{lib: lib}, _c, :unknown_function) do
    names =
      Builtins.function_names() ++ lib.function_order ++ Builtins.step_names() ++ lib.action_order

    "Available functions and actions: " <> Enum.map_join(names, ", ", &("@" <> &1))
  end

  defp hint(%{lib: lib}, c, {:type_mismatch, _, _}) do
    case Library.get_component(lib, c) || Library.get_call(lib, c) do
      %{params: params} -> "Signature: " <> Signature.typed(c, params)
      nil -> nil
    end
  end

  defp hint(_ctx, _c, _issue), do: nil
end
