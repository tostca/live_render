defmodule LiveRender.OpenUI.TestHelpers do
  @moduledoc """
  Small helpers for the OpenUI engine tests: parse a program with the fixture library, evaluate
  one statement the way a prop would be evaluated, and summarize results canonically.
  """

  alias LiveRender.OpenUI.{Conformance, Evaluator, Materializer, Parser}
  alias LiveRender.OpenUI.Parser.Stream

  @doc "The fixture library, built once per test process."
  def lib do
    case Process.get(:openui_test_lib) do
      nil ->
        lib = Conformance.library()
        Process.put(:openui_test_lib, lib)
        lib

      lib ->
        lib
    end
  end

  @doc "Parses `text` with the fixture library (or `lib`)."
  def parse(text, lib \\ lib()), do: Parser.parse(text, lib)

  @doc "The canonical fixture summary of a parse result, without the evaluated tree."
  def canonical(result, lib \\ lib()) do
    result |> Conformance.canonical(lib) |> Map.delete(:tree)
  end

  @doc "Parses `text` and returns its canonical summary."
  def summary(text, lib \\ lib()), do: text |> parse(lib) |> canonical(lib)

  @doc "Feeds `chunks` into a stream parser and returns the final result."
  def stream(chunks, lib \\ lib()) do
    s = Enum.reduce(chunks, Stream.new(lib), fn c, s -> elem(Stream.push(s, c), 0) end)
    s |> Stream.finish() |> elem(1)
  end

  @doc """
  Parses `program` and evaluates the statement `name` as a computed expression. Returns
  `{value, parser_errors, runtime_errors}`.

  Options: `:state` overrides state values, `:refs` maps query/mutation names to results,
  `:lib` replaces the library.
  """
  def eval_stmt(program, name \\ "v", opts \\ []) do
    lib = Keyword.get(opts, :lib, lib())
    result = Parser.parse(program, lib)
    syms = Map.new(result.statements, &{&1.id, &1.expr})

    ctx = %Materializer.Ctx{
      syms: syms,
      lib: lib,
      current: name,
      visited: MapSet.new([name])
    }

    {ast, ctx} = Materializer.expr(Map.fetch!(syms, name), ctx)
    state = Map.merge(result.state, Keyword.get(opts, :state, %{}))
    refs = Keyword.get(opts, :refs, %{})
    ectx = Evaluator.ctx(lib, &Map.get(state, &1), &Map.get(refs, &1))
    {value, runtime} = Evaluator.evaluate_value(ast, ectx)
    {value, Enum.reverse(ctx.errors), runtime}
  end

  @doc "Evaluates a single expression `expr` (with optional extra statements) and returns its value."
  def ev(expr, extra \\ "", opts \\ []) do
    {value, _parser, _runtime} = eval_stmt("v = " <> expr <> "\n" <> extra, "v", opts)
    value
  end

  @doc "Error codes of a list of errors."
  def codes(errors), do: Enum.map(errors, & &1.code)
end
