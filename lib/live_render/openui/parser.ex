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
    A query statement. The argument ASTs are materialized (references resolved). `deps` are the
    `$variables` written literally in its args; only they trigger a fetch (section 6.1).
    """
    defstruct [:id, :tool, :args, :defaults, :refresh, deps: [], fingerprint: nil]
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

  @doc false
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

  @doc false
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

  # The later definition of a name wins; its position stays where the name first appeared.
  @doc false
  def dedupe(stmts) do
    {order, map} =
      Enum.reduce(stmts, {[], %{}}, fn s, {order, map} ->
        order = if Map.has_key?(map, s.id), do: order, else: [s.id | order]
        {order, Map.put(map, s.id, s)}
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(map, &1))
  end

  @doc false
  def build(stmts, lib, incomplete, count, partial_ref \\ nil) do
    entry = pick_entry(stmts, lib.root)
    syms = Map.new(stmts, &{&1.id, &1.expr})

    unreached =
      for s <- stmts,
          s.kind == :value,
          entry == nil or s.id != elem(entry, 0),
          into: MapSet.new(),
          do: s.id

    entry_id = entry && elem(entry, 0)
    ctx = %Ctx{syms: syms, lib: lib, partial: incomplete, current: entry_id, unreached: unreached}

    {root, root_expression, ctx} =
      case entry do
        nil ->
          {nil, nil, ctx}

        {id, _fallback} ->
          case Materializer.value(Map.fetch!(syms, id), ctx) do
            {%Element{} = el, ctx} -> {%{el | statement_id: id}, nil, ctx}
            {ast, ctx} when is_tuple(ast) -> {nil, if(contains_component?(ast), do: ast), ctx}
            {_other, ctx} -> {nil, nil, ctx}
          end
      end

    {state, state_order, ctx} = state_declarations(stmts, ctx, lib)
    {queries, mutations, ctx} = data_statements(stmts, ctx)
    {state, state_order} = auto_declare(stmts, state, state_order, partial_ref)

    ctx = %{ctx | current: entry_id}
    component = lib.root || ""

    ctx =
      cond do
        entry == nil ->
          Validation.issue(ctx, component, "", {:no_root, :missing})

        root == nil and root_expression == nil and
            not resolves_to_component?(syms[entry_id], syms) ->
          Validation.issue(ctx, component, "", {:no_root, :not_component})

        elem(entry, 1) ->
          Validation.issue(
            ctx,
            component,
            "",
            {:no_root, if(root, do: :fallback, else: :missing)}
          )

        true ->
          ctx
      end

    %Result{
      root: root,
      root_expression: root_expression,
      entry: entry_id,
      errors: Enum.reverse(ctx.errors),
      unresolved: ctx.unres |> Enum.reverse() |> Enum.uniq(),
      orphans:
        if(entry,
          do: stmts |> Enum.map(& &1.id) |> Enum.filter(&MapSet.member?(ctx.unreached, &1)),
          else: []
        ),
      incomplete: incomplete,
      state: state,
      state_order: state_order,
      queries: queries,
      mutations: mutations,
      statements: stmts,
      statement_count: count
    }
  end

  # The entry is `root`, else the first value statement that calls the library's root component.
  defp pick_entry(stmts, root_name) do
    if Enum.any?(stmts, &(&1.id == "root")) do
      {"root", false}
    else
      Enum.find_value(stmts, fn
        %Statement{kind: :value, id: id, expr: {:call, ^root_name, _, false, _} = e}
        when root_name != nil ->
          if Materializer.component_call?(e), do: {id, true}

        _ ->
          nil
      end)
    end
  end

  defp resolves_to_component?(node, syms), do: resolves_to_component?(node, syms, MapSet.new())

  defp resolves_to_component?({:ref, n}, syms, seen) do
    if MapSet.member?(seen, n),
      do: false,
      else: resolves_to_component?(Map.get(syms, n), syms, MapSet.put(seen, n))
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
        {Map.put(state, id, default_value(value, lib)), [id | order], ctx}

      _, acc ->
        acc
    end)
    |> then(fn {state, order, ctx} -> {state, Enum.reverse(order), ctx} end)
  end

  # A default written as an expression is evaluated once, with no state and no query results.
  defp default_value(value, lib) when is_tuple(value), do: Evaluator.constant(value, lib)
  defp default_value(value, _lib), do: value

  defp data_statements(stmts, ctx) do
    {queries, mutations, ctx} =
      Enum.reduce(stmts, {[], [], ctx}, fn
        %Statement{kind: :query, id: id, expr: {:call, _, args, _, _} = expr}, {qs, ms, ctx} ->
          deps = args |> Enum.at(1) |> then(&if(&1, do: Materializer.state_refs(&1), else: []))
          {[tool, qargs, defaults, refresh], ctx} = materialize_args(args, 4, id, ctx)

          q = %Query{
            id: id,
            tool: tool,
            args: qargs,
            defaults: defaults,
            refresh: refresh,
            deps: deps,
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

    {Enum.reverse(queries), Enum.reverse(mutations), ctx}
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
      |> Enum.reduce(acc, fn name, {state, order} ->
        skip? =
          match?({^name, ids} when is_map(ids), partial_ref) and
            MapSet.member?(elem(partial_ref, 1), stmt.id)

        if skip? or Map.has_key?(state, name),
          do: {state, order},
          else: {Map.put(state, name, nil), order ++ [name]}
      end)
    end)
  end
end
