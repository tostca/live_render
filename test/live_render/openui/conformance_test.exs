defmodule LiveRender.OpenUI.ConformanceTest do
  @moduledoc """
  The OpenUI 1.0 conformance suite, pinned in `test/fixtures/openui/PINNED.md`.

  Set `OPENUI_CONFORMANCE_REPORT=path.json` to write `{"<id>": {"status", "diffs"}}` for both
  levels.
  """

  use ExUnit.Case, async: true

  alias LiveRender.OpenUI.Conformance

  # A case may be skipped only for a documented, temporary platform issue. None are skipped.
  @skip %{}

  setup_all do
    %{lib: Conformance.library()}
  end

  for id <- Conformance.cases() do
    @id id

    if reason = @skip[id] do
      @tag skip: reason
    end

    @tag level: 1
    test "level 1: #{id}", %{lib: lib} do
      diffs = Conformance.run_program(@id, lib)
      record(@id, 1, diffs)
      assert diffs == [], Enum.join([@id | diffs], "\n  ")
    end

    if Conformance.interaction_case?(id) do
      @tag level: 2
      test "level 2: #{id}", %{lib: lib} do
        diffs = Conformance.run_interactions(@id, lib)
        record(@id <> "#interactions", 2, diffs)
        assert diffs == [], Enum.join([@id | diffs], "\n  ")
      end
    end
  end

  defp record(id, level, diffs) do
    if path = System.get_env("OPENUI_CONFORMANCE_REPORT") do
      entry = %{
        "level" => level,
        "status" => if(diffs == [], do: "pass", else: "fail"),
        "diffs" => diffs
      }

      line = Jason.encode!(%{id => entry})
      File.write!(path <> ".jsonl", line <> "\n", [:append])
    end
  end
end
