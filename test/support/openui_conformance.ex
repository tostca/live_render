defmodule LiveRender.OpenUI.Conformance do
  @moduledoc """
  Runner for the OpenUI 1.0 conformance fixtures (language.md, Appendix B, and
  `test/fixtures/openui/1.0/README.md`).

  Level 1 (program) cases produce the canonical JSON — `root`, `errors`, `unresolved`, `orphans`,
  `incomplete`, `state`, `statements`, `errorObjects` — and compare it with `expected.json` using
  the README's rules. Level 2 (interaction) cases mount the program in a `LiveRender.OpenUI.Runtime`
  and replay `interactions.json`.
  """

  alias LiveRender.OpenUI.{
    ActionPlan,
    Binding,
    Editing,
    Element,
    Error,
    Evaluator,
    JS,
    Library,
    Parser,
    Rules,
    Runtime,
    Serializer
  }

  alias LiveRender.OpenUI.Parser.Stream

  @root Path.expand("../fixtures/openui/1.0", __DIR__)

  def root, do: @root

  @doc "The fixture library, with `@Upper` implemented and the test library's form metadata."
  def library do
    @root
    |> Path.join("library.json")
    |> File.read!()
    |> Library.from_json(
      functions: %{"Upper" => fn args -> String.upcase(to_string(args["text"] || "")) end},
      forms: %{"Form" => "name"},
      fields: %{"Input" => "input"}
    )
  end

  @doc "Every case id, `area/NNN-name`, sorted."
  def cases do
    for area <- ls_dirs(@root), name <- ls_dirs(Path.join(@root, area)), do: "#{area}/#{name}"
  end

  defp ls_dirs(path) do
    path |> File.ls!() |> Enum.filter(&File.dir?(Path.join(path, &1))) |> Enum.sort()
  end

  def files(id) do
    dir = Path.join(@root, id)
    dir |> File.ls!() |> Map.new(fn f -> {f, File.read!(Path.join(dir, f))} end)
  end

  def interaction_case?(id), do: File.exists?(Path.join([@root, id, "interactions.json"]))

  # ── Level 1 ──────────────────────────────────────────────────────────────

  @doc "Runs a level 1 check. Returns a list of differences (empty when the case passes)."
  def run_program(id, lib \\ library()) do
    files = files(id)

    cond do
      files["validation.json"] ->
        run_validation(files)

      files["chunks.json"] ->
        run_streaming(id, files, lib)

      files["patch.oui"] ->
        run_editing(id, files, lib)

      true ->
        check(
          id,
          Jason.decode!(files["expected.json"]),
          Parser.parse(files["input.oui"], lib),
          lib
        )
    end
  end

  defp run_streaming(id, files, lib) do
    expected = Jason.decode!(files["expected.json"])
    chunks = Jason.decode!(files["chunks.json"])

    stream =
      Enum.reduce(chunks, Stream.new(lib), fn chunk, s ->
        {s, _result} = Stream.push(s, chunk)
        s
      end)

    {_stream, streamed} = Stream.finish(stream)
    batch = Parser.parse(Enum.join(chunks), lib)

    Enum.map(check(id, expected, streamed, lib), &("streamed " <> &1)) ++
      Enum.map(check(id, expected, batch, lib), &("batch " <> &1))
  end

  defp run_editing(id, files, lib) do
    expected = Jason.decode!(files["expected.json"])
    merged = Editing.merge(files["input.oui"], files["patch.oui"])

    statements =
      merged
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^(\$?\w+)\s*=(?!=)/, line) do
          [_, name] -> [name]
          nil -> []
        end
      end)

    check(id, expected, Parser.parse(merged, lib), lib, statements)
  end

  defp run_validation(files) do
    %{"cases" => cases} = Jason.decode!(files["validation.json"])

    cases
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{"rules" => rules, "value" => value, "valid" => valid}, i} ->
      error = Rules.validate(value, rules)

      if is_nil(error) == valid,
        do: [],
        else: ["case #{i} #{Jason.encode!(rules)} #{Jason.encode!(value)}: got #{inspect(error)}"]
    end)
  end

  @doc "The canonical result of a parse at stream end."
  def canonical(result, lib) do
    state = result.state

    resolve = fn name ->
      cond do
        q = Enum.find(result.queries, &(&1.id == name)) ->
          if q.defaults,
            do: Evaluator.eval(q.defaults, ctx_for(lib, state, fn _ -> nil end)),
            else: nil

        Enum.any?(result.mutations, &(&1.id == name)) ->
          %{"status" => "idle", "data" => nil, "error" => nil}

        true ->
          nil
      end
    end

    ctx = ctx_for(lib, state, resolve)
    {tree, runtime_errors} = Evaluator.evaluate_root(result, ctx)
    errors = result.errors ++ runtime_errors

    %{
      tree: tree,
      root: summarize(tree, ctx),
      errors: Enum.map(errors, &%{"code" => &1.code, "statementId" => &1.statement_id}),
      errorObjects: Enum.map(errors, &Error.to_map/1),
      unresolved: result.unresolved,
      orphans: result.orphans,
      incomplete: result.incomplete,
      state: JS.to_json(state)
    }
  end

  defp ctx_for(lib, state, resolve) do
    Evaluator.ctx(lib, fn name -> Map.get(state, name) end, resolve)
  end

  @doc "The fixture summary of an evaluated value (README, \"How the tree is summarized\")."
  def summarize(nil, _ctx), do: nil
  def summarize(v, ctx) when is_list(v), do: Enum.map(v, &summarize(&1, ctx))

  def summarize(%Element{type_name: type, props: props}, ctx) do
    props =
      props
      |> Enum.map(fn {k, v} -> {k, summarize(v, ctx)} end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    %{"type" => type, "props" => props}
  end

  def summarize(%ActionPlan{steps: steps}, ctx),
    do: %{"actions" => Enum.map(steps, &summarize_step(&1, ctx))}

  def summarize(%Binding{target: t}, _ctx), do: %{"$binding" => t}

  def summarize(v, ctx) when is_map(v),
    do: Map.new(v, fn {k, val} -> {k, summarize(val, ctx)} end)

  def summarize(v, _ctx) when v in [:nan, :infinity, :neg_infinity], do: nil
  def summarize(v, _ctx), do: v

  defp summarize_step({:continue_conversation, msg, :none}, _ctx),
    do: %{"action" => "ToAssistant", "args" => [msg]}

  defp summarize_step({:continue_conversation, msg, context}, ctx),
    do: %{"action" => "ToAssistant", "args" => [msg, summarize(context, ctx)]}

  defp summarize_step({:open_url, url}, _ctx), do: %{"action" => "OpenUrl", "args" => [url]}

  defp summarize_step({:set, target, ast}, ctx),
    do: %{"action" => "Set", "args" => [target, summarize(Evaluator.eval(ast, ctx), ctx)]}

  defp summarize_step({:reset, targets}, _ctx), do: %{"action" => "Reset", "args" => targets}
  defp summarize_step({:run, id, _type}, _ctx), do: %{"action" => "Run", "args" => [id]}

  defp summarize_step({:custom, name, params, order}, ctx),
    do: %{"action" => name, "args" => Enum.map(order, &summarize(Map.get(params, &1), ctx))}

  # ── Comparison ───────────────────────────────────────────────────────────

  @optional ~w(state statements errorObjects)

  defp check(id, expected, result, lib, statements \\ nil) do
    actual = canonical(result, lib) |> Map.put(:statements, statements)

    diffs =
      ~w(root errors unresolved orphans incomplete state statements errorObjects)
      |> Enum.filter(&(Map.has_key?(expected, &1) or &1 not in @optional))
      |> Enum.flat_map(fn key ->
        want = Map.get(expected, key)
        got = Map.get(actual, String.to_existing_atom(key))

        if compare(key, want, got),
          do: [],
          else: ["#{key}: expected #{Jason.encode!(want)}, got #{Jason.encode!(got)}"]
      end)

    diffs ++ roundtrip(id, expected, actual, lib)
  end

  defp roundtrip(id, expected, actual, lib) do
    if String.contains?(id, "-roundtrip-") and actual.tree do
      text = Serializer.to_source(actual.tree, lib)
      again = canonical(Parser.parse(text, lib), lib).root

      if again == expected["root"],
        do: [],
        else: ["roundtrip: #{inspect(text)} parses to #{Jason.encode!(again)}"]
    else
      []
    end
  end

  defp compare("errors", want, got), do: length(want) == length(got) and claims?(want, got)
  defp compare("errorObjects", want, got), do: claims?(want, got)

  defp compare(key, want, got) when key in ["unresolved", "orphans"],
    do: as_set(want) == as_set(got)

  defp compare(_key, want, got), do: want == got

  defp as_set(list) when is_list(list), do: list |> Enum.uniq() |> Enum.sort()
  defp as_set(v), do: v

  # Each expected entry claims an actual entry that agrees on the keys it lists.
  defp claims?(expected, actual) do
    expected
    |> Enum.sort_by(&(-map_size(&1)))
    |> Enum.reduce_while(actual, fn e, pool ->
      case Enum.find_index(pool, fn a -> Enum.all?(e, fn {k, v} -> Map.get(a, k) == v end) end) do
        nil -> {:halt, :fail}
        i -> {:cont, List.delete_at(pool, i)}
      end
    end)
    |> Kernel.!=(:fail)
  end

  # ── Level 2 ──────────────────────────────────────────────────────────────

  @doc """
  Replays `interactions.json` against a mounted runtime. Tools run synchronously. Returns a list
  of differences.
  """
  def run_interactions(id, lib \\ library()) do
    files = files(id)
    %{"interactions" => steps, "expected" => expected} = Jason.decode!(files["interactions.json"])

    {initial_tools, steps} = Enum.split_while(steps, &Map.has_key?(&1, "tool"))
    agent = start_tool_agent(initial_tools)

    runtime =
      Runtime.new(lib, response: files["input.oui"], streaming: false)

    {runtime, _} = drain(Runtime.start(runtime), agent)

    {runtime, diffs} =
      Enum.reduce_while(Enum.with_index(steps), {runtime, []}, fn {step, i}, {rt, diffs} ->
        case step do
          %{"tool" => name, "result" => result} ->
            Agent.update(agent, fn s -> put_in(s.results[name], result) end)
            {:cont, {rt, diffs}}

          %{"click" => sid} ->
            case Runtime.click_statement(rt, sid) do
              {:error, :not_found} ->
                {:halt, {rt, diffs ++ ["step #{i}: nothing rendered for #{sid}"]}}

              {rt, effects} ->
                {:cont, {elem(drain({rt, effects}, agent), 0), diffs}}
            end

          %{"type" => [sid, text]} ->
            case Runtime.type_statement(rt, sid, text) do
              {:error, :not_found} ->
                {:halt, {rt, diffs ++ ["step #{i}: nothing rendered for #{sid}"]}}

              {rt, effects} ->
                {:cont, {elem(drain({rt, effects}, agent), 0), diffs}}
            end
        end
      end)

    events = Agent.get(agent, & &1.events) |> Enum.reverse()
    calls = Agent.get(agent, & &1.calls) |> Enum.reverse() |> dedupe_consecutive()
    Agent.stop(agent)

    want_events = expected["events"] || []

    events_ok =
      length(want_events) == length(events) and
        want_events
        |> Enum.zip(events)
        |> Enum.all?(fn {w, e} -> Enum.all?(w, fn {k, v} -> Map.get(e, k) == v end) end)

    diffs =
      diffs ++
        if(events_ok,
          do: [],
          else: ["events: expected #{Jason.encode!(want_events)}, got #{Jason.encode!(events)}"]
        )

    diffs =
      diffs ++
        Enum.flat_map(expected["state"] || %{}, fn {key, v} ->
          got = runtime |> Runtime.state() |> Map.get(key)

          if JS.to_json(got) == v,
            do: [],
            else: ["state #{key}: expected #{Jason.encode!(v)}, got #{inspect(got)}"]
        end)

    diffs ++
      case expected["toolCalls"] do
        nil -> []
        ^calls -> []
        want -> ["toolCalls: expected #{Jason.encode!(want)}, got #{Jason.encode!(calls)}"]
      end
  end

  defp dedupe_consecutive(calls) do
    calls |> Enum.chunk_by(& &1) |> Enum.map(&hd/1)
  end

  defp start_tool_agent(initial) do
    results = Map.new(initial, &{&1["tool"], &1["result"]})
    {:ok, agent} = Agent.start_link(fn -> %{results: results, calls: [], events: []} end)
    agent
  end

  # Executes effects synchronously until none are left.
  defp drain({runtime, effects}, agent) do
    Enum.reduce(effects, {runtime, []}, fn effect, {rt, _} ->
      case effect do
        {:event, event} ->
          Agent.update(agent, &%{&1 | events: [JS.to_json(event) | &1.events]})
          {rt, []}

        {:call_tool, ref, name, args} ->
          result =
            Agent.get_and_update(agent, fn s ->
              case Map.fetch(s.results, name) do
                {:ok, r} ->
                  {{:ok, r},
                   %{s | calls: [%{"tool" => name, "args" => JS.to_json(args)} | s.calls]}}

                :error ->
                  {{:error, {:tool_not_found, Map.keys(s.results)}}, s}
              end
            end)

          drain(Runtime.tool_result(rt, ref, result), agent)

        _other ->
          {rt, []}
      end
    end)
  end
end
