defmodule LiveRender.OpenUI.Editing do
  @moduledoc """
  Incremental editing (language.md, section 7): merges a patch — only the changed statements —
  into the current program by statement name.

    * A patch statement whose name exists replaces the original; a new name is appended.
    * A top-level `name = null` in the patch deletes the statement (state declarations included;
      the store key stays).
    * Afterwards, statements `root` cannot reach are removed, unless there is no `root`
      statement. State declarations are always kept.

  Both texts are read with the parser's own rules (fences, comments, statement boundaries
  including multi-line ternaries), so the merge splits statements exactly as parsing does. Merge
  a patch once it has finished streaming.
  """

  alias LiveRender.OpenUI.{Lexer, Materializer, Parser, Source, Statements}

  @doc "Returns the merged program text."
  @spec merge(String.t(), String.t()) :: String.t()
  def merge(existing, patch) do
    current = statements(existing)
    changes = statements(patch)

    cond do
      current == [] ->
        changes |> Enum.reject(&(&1.expr == {:null})) |> Enum.map_join("\n", & &1.source)

      changes == [] ->
        existing

      true ->
        current |> apply_patch(changes) |> collect_garbage() |> Enum.map_join("\n", & &1.source)
    end
  end

  @doc "The statements of a program text, each name once (the later definition wins)."
  def statements(text) do
    prepared = Source.prepare(text)
    {closed, _} = Source.auto_close(prepared)

    closed
    |> Lexer.tokenize()
    |> Statements.split()
    |> Enum.map(&Parser.classify(&1, closed))
    |> Parser.dedupe()
  end

  defp apply_patch(current, changes) do
    Enum.reduce(changes, current, fn change, acc ->
      index = Enum.find_index(acc, &(&1.id == change.id))

      cond do
        change.expr == {:null} and index -> List.delete_at(acc, index)
        change.expr == {:null} -> acc
        index -> List.replace_at(acc, index, change)
        true -> acc ++ [change]
      end
    end)
  end

  defp collect_garbage(stmts) do
    by_id = Map.new(stmts, &{&1.id, &1})

    if Map.has_key?(by_id, "root") do
      reachable = reach(["root"], by_id, MapSet.new(["root"]))
      Enum.filter(stmts, &(MapSet.member?(reachable, &1.id) or &1.kind == :state))
    else
      stmts
    end
  end

  defp reach([], _by_id, seen), do: seen

  defp reach([id | rest], by_id, seen) do
    refs =
      case Map.fetch(by_id, id) do
        {:ok, stmt} -> refs(stmt.expr)
        :error -> []
      end

    new = Enum.reject(refs, &(MapSet.member?(seen, &1) or not Map.has_key?(by_id, &1)))
    reach(new ++ rest, by_id, Enum.reduce(new, seen, &MapSet.put(&2, &1)))
  end

  # Statement names `expr` refers to. As in the materializer, an `@Each` loop variable is not a
  # reference inside its template (nor is the variable argument itself), so a statement with the
  # same name is not reached through it.
  defp refs(expr), do: refs(expr, %{}, [])

  defp refs({:ref, n}, scoped, acc), do: if(Map.has_key?(scoped, n), do: acc, else: [n | acc])

  defp refs({:call, "Each", [array, var_node | templates], _, _} = node, scoped, acc)
       when templates != [] do
    case Materializer.loop_var(var_node) do
      nil ->
        walk_children(node, scoped, acc)

      var ->
        inner = Map.put(scoped, var, true)
        Enum.reduce(templates, refs(array, scoped, acc), &refs(&1, inner, &2))
    end
  end

  defp refs(node, scoped, acc), do: walk_children(node, scoped, acc)

  defp walk_children(node, scoped, acc) do
    case node do
      {:call, _, args, _, _} -> Enum.reduce(args, acc, &refs(&1, scoped, &2))
      {:arr, els} -> Enum.reduce(els, acc, &refs(&1, scoped, &2))
      {:obj, entries} -> Enum.reduce(entries, acc, fn {_, n}, a -> refs(n, scoped, a) end)
      {:bin, _, l, r} -> refs(r, scoped, refs(l, scoped, acc))
      {:unary, _, x} -> refs(x, scoped, acc)
      {:ternary, c, t, e} -> refs(e, scoped, refs(t, scoped, refs(c, scoped, acc)))
      {:member, o, _} -> refs(o, scoped, acc)
      {:index, o, i} -> refs(i, scoped, refs(o, scoped, acc))
      {:assign, _, v} -> refs(v, scoped, acc)
      _ -> acc
    end
  end
end
