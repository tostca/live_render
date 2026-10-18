defmodule LiveRender.OpenUI.Tree do
  @moduledoc """
  Navigation in an evaluated tree.

  A *path* addresses a component instance from the root: a list of prop names and list indexes,
  e.g. `["children", 0, "children", 2]`. Renderers put the path of each interactive element into
  its events, and the runtime walks its own tree to find the element again, so the client never
  sends actions, tool names or state names.

  The *form name* of an element is the name given by its nearest enclosing form component
  (language.md, section 5.3); nil means page level.
  """

  alias LiveRender.OpenUI.{Element, Library}

  @type path :: [String.t() | non_neg_integer()]

  @doc "The element at `path`, with its form name. Returns `{:ok, element, form_name}` or `:error`."
  @spec at_path(Element.t() | nil, Library.t(), path()) ::
          {:ok, Element.t(), String.t() | nil} | :error
  def at_path(nil, _lib, _path), do: :error

  def at_path(%Element{} = root, lib, path) when is_list(path),
    do: walk_path(root, path, form_of(root, lib, nil), lib)

  def at_path(_, _, _), do: :error

  defp walk_path(%Element{} = el, [], form, _lib), do: {:ok, el, form}

  defp walk_path(%Element{props: props}, [key | rest], form, lib) when is_binary(key) do
    case Map.fetch(props, key) do
      {:ok, value} -> descend(value, rest, form, lib)
      :error -> :error
    end
  end

  defp walk_path(_, _, _, _), do: :error

  defp descend(%Element{} = el, rest, form, lib),
    do: walk_path(el, rest, form_of(el, lib, form), lib)

  defp descend(list, [i | rest], form, lib) when is_list(list) and is_integer(i) and i >= 0 do
    case Enum.fetch(list, i) do
      {:ok, v} -> descend(v, rest, form, lib)
      :error -> :error
    end
  end

  defp descend(map, [k | rest], form, lib)
       when is_map(map) and not is_struct(map) and is_binary(k) do
    case Map.fetch(map, k) do
      {:ok, v} -> descend(v, rest, form, lib)
      :error -> :error
    end
  end

  defp descend(_, _, _, _), do: :error

  @doc "The form name an element gives its subtree, or `outer` when it is not a form component."
  def form_of(%Element{type_name: type, props: props}, lib, outer) do
    case Library.get_component(lib, type) do
      %{form: prop} when is_binary(prop) ->
        case Map.get(props, prop) do
          name when is_binary(name) and name != "" -> name
          _ -> outer
        end

      _ ->
        outer
    end
  end

  @doc """
  Every element under `root` (root included), depth first in prop order:
  `[{element, path, form_name}]`.
  """
  def elements(nil, _lib), do: []

  def elements(%Element{} = root, lib) do
    root |> collect([], form_of(root, lib, nil), lib, []) |> Enum.reverse()
  end

  defp collect(%Element{props: props} = el, path, form, lib, acc) do
    acc = [{el, path, form} | acc]
    keys = prop_order(el, lib)

    Enum.reduce(keys, acc, fn key, acc ->
      collect_value(Map.get(props, key), path ++ [key], form, lib, acc)
    end)
  end

  defp collect_value(%Element{} = el, path, form, lib, acc),
    do: collect(el, path, form_of(el, lib, form), lib, acc)

  defp collect_value(list, path, form, lib, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {v, i}, acc -> collect_value(v, path ++ [i], form, lib, acc) end)
  end

  defp collect_value(map, path, form, lib, acc) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(acc, fn {k, v}, acc -> collect_value(v, path ++ [k], form, lib, acc) end)
  end

  defp collect_value(_, _path, _form, _lib, acc), do: acc

  # Props in the library's positional order, then any others alphabetically.
  defp prop_order(%Element{type_name: type, props: props}, lib) do
    declared =
      case Library.get_component(lib, type) do
        nil -> []
        comp -> Enum.map(comp.params, & &1.name)
      end

    present = declared |> Enum.filter(&Map.has_key?(props, &1))
    present ++ (props |> Map.keys() |> Enum.reject(&(&1 in declared)) |> Enum.sort())
  end

  @doc "The first element (depth first) that came from statement `id`."
  def find_statement(root, lib, id) do
    Enum.find_value(elements(root, lib), :error, fn
      {%Element{statement_id: ^id} = el, path, form} -> {:ok, el, path, form}
      _ -> nil
    end)
  end

  @doc "Encodes a path for a `phx-value-*` attribute."
  def encode_path(path), do: Enum.map_join(path, ".", &to_string/1)

  @doc "Decodes a path from an event payload. Returns `{:ok, path}` or `:error`."
  def decode_path(""), do: {:ok, []}

  def decode_path(str) when is_binary(str) and byte_size(str) <= 2048 do
    segments =
      str
      |> String.split(".")
      |> Enum.map(fn seg ->
        case Integer.parse(seg) do
          {i, ""} when i >= 0 -> i
          _ -> seg
        end
      end)

    {:ok, segments}
  end

  def decode_path(_), do: :error
end
