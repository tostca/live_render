defmodule LiveRender.OpenUI.Parser do
  @moduledoc """
  Parses OpenUI Lang text into a `ParseResult` (language.md, sections 1, 2 and 8).

      result = Parser.parse(text, library)
      result.root        #=> %Element{} | nil
      result.errors      #=> [%Error{}]

  For chunked input use `LiveRender.OpenUI.Parser.Stream`, whose final result equals `parse/2`
  on the joined text (section 4).
  """

  alias LiveRender.OpenUI.{
    Builtins,
    Element,
    Evaluator,
    ExprParser,
    Lexer,
    Library,
    Materializer,
    Source,
    Statements,
    Validation
  }

  alias LiveRender.OpenUI.Materializer.Ctx

  defmodule Statement do
    @moduledoc """
    A classified statement (section 2.1). `kind` is `:query`, `:mutation`, `:state` or `:value`.
    `source` is the statement's text as written, used by the edit merge.
    """
    defstruct [:id, :kind, :expr, :source]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: :value | :state | :query | :mutation,
            expr: tuple(),
            source: String.t() | nil
          }
  end

  defmodule Query do
    @moduledoc """
    A query statement. The argument ASTs are materialized (references resolved). `waits_for` are
    the queries whose results the tool name or args read (section 6.1). `deps` are the
    `$variables` written literally in its args; only they trigger a fetch (section 6.1).
    """
    defstruct [:id, :tool, :args, :defaults, :refresh, deps: [], waits_for: [], fingerprint: nil]
  end

  defmodule Mutation do
    @moduledoc "A mutation statement, with materialized argument ASTs."
    defstruct [:id, :tool, :args, fingerprint: nil]
  end

  defmodule Result do
    @moduledoc """
    The result of a parse.

      * `root`: the entry element, or nil
      * `root_expression`: set when the entry picks a component at runtime (`root = $t ? A : B`)
      * `entry`: the entry statement id, or nil
      * `errors`: parser errors (`%Error{}`), in the order they were found
      * `unresolved`, `orphans`: statement names (section 2.3)
      * `incomplete`: the input ended inside an unclosed string or bracket
      * `state`: `%{"$name" => default}`, `state_order` its declaration order
      * `queries`, `mutations`: data statements
      * `statements`: the classified statements, each name once, in first-definition order
    """
    defstruct root: nil,
              root_expression: nil,
              entry: nil,
              errors: [],
              unresolved: [],
              orphans: [],
              incomplete: false,
              state: %{},
              state_order: [],
              queries: [],
              mutations: [],
              statements: [],
              statement_count: 0

    @type t :: %__MODULE__{}
  end

  @doc "Parses complete text."
  @spec parse(String.t(), Library.t(), keyword()) :: Result.t()
  def parse(text, %Library{} = lib, opts \\ []) do
    prepared = Source.prepare(text, opts)
    from_prepared(prepared, lib)
  end

  @doc "Parses text that has already been through `LiveRender.OpenUI.Source.prepare/2`."
  @spec from_prepared(String.t(), Library.t()) :: Result.t()
  def from_prepared("", _lib), do: %Result{incomplete: true}

  def from_prepared(prepared, lib) do
    {closed, incomplete} = Source.auto_close(prepared)
    raws = closed |> Lexer.tokenize() |> Statements.split()

    case raws do
      [] ->
        %Result{incomplete: incomplete}

      _ ->
        stmts = Enum.map(raws, &classify(&1, closed))
        build(dedupe(stmts), lib, incomplete, length(raws))
    end
  end

  @doc """
  Parses a raw statement's expression and classifies it (section 2.1). `text` is the prepared text
  the statement's offsets point into; the statement keeps its source slice for the edit merge.
  """
  @spec classify(Statements.Raw.t(), String.t()) :: Statement.t()
  def classify(%Statements.Raw{} = raw, text) do
    expr = ExprParser.parse(raw.tokens)

    kind =
      case expr do
        {:call, "Query", _, _, _} -> :query
        {:call, "Mutation", _, _, _} -> :mutation
        _ when raw.id_kind == :state -> :state
        _ -> :value
      end

    stop = raw.stop || byte_size(text)
    source = text |> binary_part(raw.start, stop - raw.start) |> String.trim()
    %Statement{id: raw.id, kind: kind, expr: expr, source: source}
  end

  @doc """
  Keeps each statement name once (section 2.4): the later definition wins, and its position stays
  where the name first appeared.
  """
  @spec dedupe([Statement.t()]) :: [Statement.t()]
  def dedupe(stmts) do
    {order, map} =
      Enum.reduce(stmts, {[], %{}}, fn s, {order, map} ->
        order = if Map.has_key?(map, s.id), do: order, else: [s.id | order]
        {order, Map.put(map, s.id, s)}
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(map, &1))
  end

  @doc """
  Builds the parse result from deduplicated statements: picks the entry, materializes it, extracts
  state, query and mutation statements, and reports `no-root`. `partial_ref` is
  `{"$name", pending_statement_ids}` for a `$name` that may still be growing at the end of a stream.
  """
  @spec build([Statement.t()], Library.t(), boolean(), non_neg_integer(), term()) :: Result.t()
  def build(stmts, lib, incomplete, count, partial_ref \\ nil) do
    entry = pick_entry(stmts, lib.root)
    entry_id = entry && elem(entry, 0)
    syms = Map.new(stmts, &{&1.id, &1.expr})
    unreached = for s <- stmts, s.kind == :value, s.id != entry_id, into: MapSet.new(), do: s.id
    ctx = %Ctx{syms: syms, lib: lib, partial: incomplete, current: entry_id, unreached: unreached}

    {root, root_expression, ctx} = materialize_entry(entry_id, syms, ctx)
    {state, state_order, ctx} = state_declarations(stmts, ctx, lib)
    {queries, mutations, ctx} = data_statements(stmts, ctx)
    {state, state_order} = auto_declare(stmts, state, state_order, partial_ref)
    ctx = report_no_root(%{ctx | current: entry_id}, entry, root || root_expression, syms, lib)

    %Result{
      root: root,
      root_expression: root_expression,
      entry: entry_id,
      errors: Enum.reverse(ctx.errors),
      unresolved: ctx.unres |> Enum.reverse() |> Enum.uniq(),
      orphans: orphans(entry, stmts, ctx.unreached),
      incomplete: incomplete,
      state: state,
      state_order: state_order,
      queries: queries,
      mutations: mutations,
      statements: stmts,
      statement_count: count
    }
  end

  defp materialize_entry(nil, _syms, ctx), do: {nil, nil, ctx}

  defp materialize_entry(id, syms, ctx) do
    case Materializer.value(Map.fetch!(syms, id), ctx) do
      {%Element{} = el, ctx} -> {%{el | statement_id: id}, nil, ctx}
      {ast, ctx} when is_tuple(ast) -> {nil, if(contains_component?(ast), do: ast), ctx}
      {_other, ctx} -> {nil, nil, ctx}
    end
  end

  # Section 2.2: no entry is fatal; an entry that is not a component is fatal (unless it names a
  # component call that validation dropped, which has its own error); a fallback entry warns.
  defp report_no_root(ctx, nil, _rendered, _syms, lib),
    do: Validation.issue(ctx, lib.root || "", "", {:no_root, :missing})

  defp report_no_root(ctx, {id, fallback?}, rendered, syms, lib) do
    cond do
      rendered == nil and not resolves_to_component?(syms[id], syms) ->
        Validation.issue(ctx, lib.root || "", "", {:no_root, :not_component})

      fallback? ->
        reason = if rendered, do: :fallback, else: :missing
        Validation.issue(ctx, lib.root || "", "", {:no_root, reason})

      true ->
        ctx
    end
  end

  # With no entry nothing is reachable, and `no-root` alone describes the problem.
  defp orphans(nil, _stmts, _unreached), do: []

  defp orphans(_entry, stmts, unreached),
    do: for(s <- stmts, MapSet.member?(unreached, s.id), do: s.id)

  # The entry is `root`, else the first value statement that calls the library's root component.
  defp pick_entry(stmts, root_name) do
    if Enum.any?(stmts, &(&1.id == "root")),
      do: {"root", false},
      else: Enum.find_value(stmts, &fallback_entry(&1, root_name))
  end

  defp fallback_entry(
         %Statement{kind: :value, id: id, expr: {:call, name, _, false, _} = e},
         name
       )
       when is_binary(name) do
    if Materializer.component_call?(e), do: {id, true}
  end

  defp fallback_entry(_stmt, _root_name), do: nil

  defp resolves_to_component?(node, syms), do: resolves_to_component?(node, syms, %{})

  defp resolves_to_component?({:ref, n}, syms, seen) do
    if Map.has_key?(seen, n),
      do: false,
      else: resolves_to_component?(Map.get(syms, n), syms, Map.put(seen, n, true))
  end

  defp resolves_to_component?(node, _syms, _seen), do: Materializer.component_call?(node)

  defp contains_component?(ast) do
    Materializer.walk(ast, false, fn node, found ->
      found or Materializer.component_call?(node)
    end)
  end

  defp state_declarations(stmts, ctx, lib) do
    Enum.reduce(stmts, {%{}, [], ctx}, fn
      %Statement{kind: :state, id: id, expr: expr}, {state, order, ctx} ->
        {value, ctx} = Materializer.value(expr, ctx)
        {Map.put(state, id, default_value(value, state, lib)), [id | order], ctx}

      _, acc ->
        acc
    end)
    |> then(fn {state, order, ctx} -> {state, Enum.reverse(order), ctx} end)
  end

  # A default written as an expression is evaluated once, with the defaults declared before it;
  # query results read as null. Library functions and actions run only in the client, so a default
  # that calls one is null (section 5.1).
  defp default_value(value, declared, lib) when is_tuple(value) do
    if only_builtin_functions?(value), do: Evaluator.constant(value, lib, declared)
  end

  defp default_value(list, declared, lib) when is_list(list),
    do: Enum.map(list, &default_value(&1, declared, lib))

  defp default_value(map, declared, lib) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, default_value(v, declared, lib)} end)

  defp default_value(value, _declared, _lib), do: value

  @builtin_functions Builtins.function_names()

  defp only_builtin_functions?(ast) do
    Materializer.walk(ast, true, fn
      {:call, name, _, _, _}, ok -> ok and name in @builtin_functions
      _, ok -> ok
    end)
  end

  defp data_statements(stmts, ctx) do
    {queries, mutations, ctx} =
      Enum.reduce(stmts, {[], [], ctx}, fn
        %Statement{kind: :query, id: id, expr: {:call, _, args, _, _} = expr}, {qs, ms, ctx} ->
          {[tool, qargs, defaults, refresh], ctx} = materialize_args(args, 4, id, ctx)
          # Read from the resolved args, so state reached through a statement counts (1.1).
          deps = if qargs, do: Materializer.state_refs(qargs), else: []

          q = %Query{
            id: id,
            tool: tool,
            args: qargs,
            defaults: defaults,
            refresh: refresh,
            deps: deps,
            waits_for: query_reads([tool, qargs]),
            fingerprint: :erlang.phash2(expr)
          }

          {[q | qs], ms, ctx}

        %Statement{kind: :mutation, id: id, expr: {:call, _, args, _, _} = expr}, {qs, ms, ctx} ->
          {[tool, margs], ctx} = materialize_args(args, 2, id, ctx)
          m = %Mutation{id: id, tool: tool, args: margs, fingerprint: :erlang.phash2(expr)}
          {qs, [m | ms], ctx}

        _, acc ->
          acc
      end)

    queries = Enum.reverse(queries)
    {queries, Enum.reverse(mutations), report_query_cycles(queries, ctx)}
  end

  # Names of the queries whose results the expressions read.
  defp query_reads(nodes) do
    nodes
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce([], &Materializer.walk(&1, &2, fn node, acc -> add_query_read(node, acc) end))
    |> Enum.reverse()
  end

  defp add_query_read({:rref, name, :query}, acc),
    do: if(name in acc, do: acc, else: [name | acc])

  defp add_query_read(_node, acc), do: acc

  # Queries that read each other's results, directly or around a loop, can never run first
  # (section 6.1). Each loop is reported once, members in statement order, on its first member.
  defp report_query_cycles(queries, ctx) do
    order = queries |> Enum.with_index() |> Map.new(fn {q, i} -> {q.id, i} end)
    reads = Map.new(queries, &{&1.id, &1.waits_for})

    {_done, cycles} =
      Enum.reduce(queries, {MapSet.new(), []}, fn q, {done, cycles} ->
        if MapSet.member?(done, q.id),
          do: {done, cycles},
          else: visit_query(q.id, [], reads, order, {done, cycles})
      end)

    cycles
    |> Enum.reverse()
    |> Enum.reduce(ctx, fn [first | _] = cycle, ctx ->
      outer = ctx.current
      ctx = Validation.issue(%{ctx | current: first}, "Query", "", {:query_cycle, cycle})
      %{ctx | current: outer}
    end)
  end

  defp visit_query(id, path, reads, order, {done, cycles}) do
    path = path ++ [id]

    {done, cycles} =
      Enum.reduce(Map.fetch!(reads, id), {done, cycles}, fn dep, {done, cycles} ->
        cond do
          at = Enum.find_index(path, &(&1 == dep)) ->
            cycle = path |> Enum.drop(at) |> Enum.sort_by(&Map.fetch!(order, &1))
            {done, [cycle | cycles]}

          Map.has_key?(reads, dep) and not MapSet.member?(done, dep) ->
            visit_query(dep, path, reads, order, {done, cycles})

          true ->
            {done, cycles}
        end
      end)

    {MapSet.put(done, id), cycles}
  end

  # References inside Query and Mutation args resolve like anywhere else and make their statements
  # reachable (sections 2.3 and 6.1).
  defp materialize_args(args, count, id, ctx) do
    outer = ctx.current
    ctx = %{ctx | current: id}

    {nodes, ctx} =
      Enum.reduce(0..(count - 1), {[], ctx}, fn i, {acc, ctx} ->
        case Enum.at(args, i) do
          nil ->
            {[nil | acc], ctx}

          node ->
            {v, ctx} = Materializer.expr(node, ctx)
            {[v | acc], ctx}
        end
      end)

    {Enum.reverse(nodes), %{ctx | current: outer}}
  end

  # An undeclared `$name` is declared with null (section 5.1). A `$name` that ends the streamed text
  # may still be growing, so the pending statements do not declare it.
  defp auto_declare(stmts, state, order, partial_ref) do
    Enum.reduce(stmts, {state, order}, fn stmt, acc ->
      nodes =
        case stmt do
          %Statement{kind: k, expr: {:call, _, args, _, _}} when k in [:query, :mutation] -> args
          %Statement{expr: expr} -> [expr]
        end

      nodes
      |> Enum.flat_map(&Materializer.state_refs/1)
      |> Enum.reject(&growing?(&1, stmt.id, partial_ref))
      |> Enum.reduce(acc, &declare_null/2)
    end)
  end

  defp growing?(name, stmt_id, {name, pending}), do: MapSet.member?(pending, stmt_id)
  defp growing?(_name, _stmt_id, _partial_ref), do: false

  defp declare_null(name, {state, order}) do
    if Map.has_key?(state, name),
      do: {state, order},
      else: {Map.put(state, name, nil), order ++ [name]}
  end
end
