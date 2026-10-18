defmodule LiveRender.OpenUI.RuntimeQueriesTest do
  @moduledoc "Query lifecycle (language.md, section 6.1) and tool resolution (6.4)."

  use ExUnit.Case, async: true

  alias LiveRender.OpenUI.Runtime
  alias LiveRender.OpenUI.RuntimeHarness, as: H

  @filter """
  $status = "open"
  root = Stack([filter, count])
  filter = Input("status", "Status", $status)
  count = Metric("Tickets", @Count(tickets.rows))
  tickets = Query("listTickets", {status: $status}, {rows: []})
  """

  defp count(h), do: H.props(h, "count")["value"]

  describe "when queries run" do
    test "a query runs once the stream ends, never while streaming" do
      h = H.mount("", streaming: true, tools: %{"listTickets" => %{"rows" => [1]}})
      h = H.push(h, @filter)
      assert h.calls == []
      assert count(h) == 0

      h = H.end_stream(h)
      assert [%{tool: "listTickets", args: %{"status" => "open"}}] = h.calls
      assert count(h) == 1
    end

    test "a query the entry does not reach still runs" do
      h =
        H.mount(
          """
          root = Stack([Text("hi")])
          unused = Query("listTickets", {}, {rows: []})
          """,
          tools: %{"listTickets" => %{"rows" => []}}
        )

      assert H.call_names(h) == ["listTickets"]
    end

    test "a query refetches when a $variable written in its args changes" do
      h = H.mount(@filter, tools: %{"listTickets" => fn %{"status" => s} -> %{"rows" => [s]} end})
      h = H.input(h, "filter", "closed")

      assert Enum.map(h.calls, & &1.args) == [%{"status" => "open"}, %{"status" => "closed"}]
      assert count(h) == 1
    end

    test "setting a $variable to the value it had does not refetch" do
      h = H.mount(@filter, tools: %{"listTickets" => %{"rows" => []}})
      h = H.input(h, "filter", "open")
      assert length(h.calls) == 1
    end

    test "returning to earlier args fetches again" do
      h = H.mount(@filter, tools: %{"listTickets" => %{"rows" => []}})
      h = h |> H.input("filter", "closed") |> H.input("filter", "open")
      assert Enum.map(h.calls, & &1.args["status"]) == ["open", "closed", "open"]
    end

    test "state reached through a referenced statement does not trigger a fetch" do
      h =
        H.mount(
          """
          $status = "open"
          $other = "a"
          root = Stack([filter, other])
          filter = Input("status", "Status", $status)
          other = Input("other", "Other", $other)
          label = "x-" + $other
          tickets = Query("listTickets", {status: $status, label: label}, {rows: []})
          """,
          tools: %{"listTickets" => %{"rows" => []}}
        )

      h = H.input(h, "other", "b")
      assert [%{args: %{"label" => "x-a"}}] = h.calls

      # The next fetch evaluates the args when it starts, so it sees the new value.
      h = H.input(h, "filter", "closed")
      assert List.last(h.calls).args == %{"status" => "closed", "label" => "x-b"}
    end

    test "query args that reference other statements resolve to their values" do
      h =
        H.mount(
          """
          root = Stack([Text("x")])
          limit = 5
          filters = {status: "open", limit: limit}
          other = Query("count", {}, {total: 3})
          tickets = Query("listTickets", {filters: filters, total: other.total, n: @Count([1, 2])}, {rows: []})
          """,
          tools: %{"listTickets" => %{"rows" => []}, "count" => :hold}
        )

      call = Enum.find(h.calls, &(&1.tool == "listTickets"))

      assert call.args == %{
               "filters" => %{"status" => "open", "limit" => 5},
               "total" => 3,
               "n" => 2
             }
    end

    test "a query with no args object calls the tool with an empty map" do
      h =
        H.mount(~s|root = Stack([Text("x")])\nq = Query("listTickets")|,
          tools: %{"listTickets" => []}
        )

      assert [%{args: %{}}] = h.calls
    end
  end

  describe "results" do
    test "references read the defaults before the first result, then the latest result" do
      h = H.mount(@filter, tools: %{"listTickets" => :hold})
      assert count(h) == 0
      assert Runtime.query_status(h.rt)["__openui_loading"] == ["tickets"]
      assert Runtime.query_status(h.rt)["__openui_refetching"] == []

      [ref] = H.pending_refs(h)
      h = H.deliver(h, ref, {:ok, %{"rows" => [1, 2]}})
      assert count(h) == 2
      assert Runtime.query_status(h.rt)["__openui_loading"] == []
    end

    test "the previous result stays visible while a fetch for new args is in flight" do
      h = H.mount(@filter, tools: %{"listTickets" => :hold})
      [first] = H.pending_refs(h)
      h = H.deliver(h, first, {:ok, %{"rows" => [1, 2, 3]}})

      h = H.input(h, "filter", "closed")
      assert count(h) == 3
      assert Runtime.query_status(h.rt)["__openui_refetching"] == ["tickets"]

      [second] = H.pending_refs(h)
      h = H.deliver(h, second, {:ok, %{"rows" => [1]}})
      assert count(h) == 1
    end

    test "a result for stale args is discarded, whatever order results arrive in" do
      h = H.mount(@filter, tools: %{"listTickets" => :hold})
      h = h |> H.input("filter", "closed") |> H.input("filter", "pending")
      [open, closed, pending] = H.pending_refs(h)

      h = H.deliver(h, pending, {:ok, %{"rows" => [1, 2, 3]}})
      assert count(h) == 3

      h =
        h |> H.deliver(closed, {:ok, %{"rows" => [1]}}) |> H.deliver(open, {:ok, %{"rows" => []}})

      assert count(h) == 3
    end

    test "a stale error is discarded too" do
      h = H.mount(@filter, tools: %{"listTickets" => :hold})
      h = H.input(h, "filter", "closed")
      [open, closed] = H.pending_refs(h)

      h = H.deliver(h, open, {:error, "boom"})
      assert Runtime.errors(h.rt) == []
      h = H.deliver(h, closed, {:ok, %{"rows" => [1]}})
      assert count(h) == 1
      assert h.errors == []
    end

    test "tool results are normalized to OpenUI values" do
      h = H.mount(@filter, tools: %{"listTickets" => %{rows: [%{id: 1, at: ~D[2026-01-02]}]}})
      assert [%{"id" => 1, "at" => "2026-01-02"}] = resolve_rows(h)
    end

    defp resolve_rows(h) do
      ctx = Runtime.eval_ctx(h.rt)
      ctx.resolve_ref.("tickets")["rows"]
    end
  end

  describe "@Run on a query" do
    @refresh """
    root = Stack([count, reload])
    count = Metric("Tickets", @Count(tickets.rows))
    reload = Button("Reload", @Run(tickets))
    tickets = Query("listTickets", {}, {rows: []})
    """

    test "fetches again" do
      h = H.mount(@refresh, tools: %{"listTickets" => %{"rows" => [1]}})
      h = H.click(h, "reload")
      assert H.call_names(h) == ["listTickets", "listTickets"]
    end

    test "a fetch after a result counts as refetching" do
      h = H.mount(@refresh, tools: %{"listTickets" => %{"rows" => [1]}})
      h = h |> H.put_tool("listTickets", :hold) |> H.click("reload")

      assert Runtime.query_status(h.rt)["__openui_loading"] == ["tickets"]
      assert Runtime.query_status(h.rt)["__openui_refetching"] == ["tickets"]
      assert count(h) == 1
    end

    test "while a fetch is in flight, fetches once more after it" do
      h = H.mount(@refresh, tools: %{"listTickets" => :hold})
      h = h |> H.click("reload") |> H.click("reload")
      assert length(h.calls) == 1

      [first] = H.pending_refs(h)
      h = H.deliver(h, first, {:ok, %{"rows" => [1]}})
      assert length(h.calls) == 2
      assert count(h) == 1

      [second] = H.pending_refs(h)
      h = H.deliver(h, second, {:ok, %{"rows" => [1, 2]}})
      assert length(h.calls) == 2
      assert count(h) == 2
    end

    test "never stops the plan" do
      h =
        H.mount(
          """
          root = Stack([go])
          go = Button("Go", Action([@Run(tickets), @ToAssistant("after")]))
          tickets = Query("listTickets", {}, {rows: []})
          """,
          tools: %{"listTickets" => :hold}
        )

      h = H.click(h, "go")
      assert [%{"humanFriendlyMessage" => "after"}] = h.events
    end
  end

  describe "refresh interval" do
    @timed """
    root = Stack([count])
    count = Metric("Tickets", @Count(tickets.rows))
    tickets = Query("listTickets", {}, {rows: []}, 5)
    """

    test "schedules a timer that refetches and reschedules" do
      h = H.mount(@timed, tools: %{"listTickets" => %{"rows" => [1]}})
      assert [{ref, 5000}] = Map.to_list(h.timers)
      assert length(h.calls) == 1

      h = H.fire(h, ref)
      assert length(h.calls) == 2
      assert [{next, 5000}] = Map.to_list(h.timers)
      assert next != ref
    end

    test "a timer skips the fetch while one is in flight, and keeps ticking" do
      h = H.mount(@timed, tools: %{"listTickets" => :hold})
      [ref] = Map.keys(h.timers)
      h = H.fire(h, ref)
      assert length(h.calls) == 1
      assert [_next] = Map.keys(h.timers)
    end

    test "an unknown or superseded timer does nothing" do
      h = H.mount(@timed, tools: %{"listTickets" => %{"rows" => []}})
      [ref] = Map.keys(h.timers)
      h = H.fire(h, ref)
      h = H.reset(h)

      assert {_, []} = Runtime.timer(h.rt, ref)
      assert {_, []} = Runtime.timer(h.rt, 9999)
    end

    test "a refresh interval below one second runs every second" do
      h =
        H.mount(String.replace(@timed, "{rows: []}, 5", "{rows: []}, 0.2"),
          tools: %{"listTickets" => []}
        )

      assert [1000] = Map.values(h.timers)
    end

    test "removing the interval stops the timer" do
      h = H.mount(@timed, tools: %{"listTickets" => []})
      [ref] = Map.keys(h.timers)
      h = H.run(h, Runtime.set_response(h.rt, String.replace(@timed, ", 5)", ")"), false))
      assert h |> H.reset() |> H.fire(ref) |> Map.get(:calls) == []
    end

    test "a new interval replaces the old timer" do
      h = H.mount(@timed, tools: %{"listTickets" => []})
      [old] = Map.keys(h.timers)
      h = H.reset(h)
      h = H.run(h, Runtime.set_response(h.rt, String.replace(@timed, ", 5)", ", 10)"), false))
      assert [{new, 10_000}] = Map.to_list(h.timers)
      h = H.reset(h)
      assert H.fire(h, old).calls == []
      assert length(H.fire(h, new).calls) == 1
    end

    test "a timer does not fetch while a new stream is streaming" do
      h = H.mount(@timed, tools: %{"listTickets" => %{"rows" => [1]}})
      [ref] = Map.keys(h.timers)
      h = H.run(h, Runtime.set_response(h.rt, @timed, true))
      h = H.reset(h)

      h = H.fire(h, ref)
      assert h.calls == []
    end
  end

  describe "tool resolution and errors" do
    test "a missing tool keeps the defaults and reports tool-not-found with the available tools" do
      h = H.mount(@filter, tools: %{"other" => [], "another" => []})
      assert count(h) == 0

      assert [[error]] = h.errors
      assert error.code == "tool-not-found"
      assert error.source == :query
      assert error.statement_id == "tickets"
      assert error.tool_name == "listTickets"
      assert error.hint == "Available tools: another, other"
      assert Runtime.query_status(h.rt)["__openui_errors"] == [error]
    end

    test "a missing tool with no tools at all has no hint" do
      h = H.mount(@filter, tools: %{})
      assert [[%{code: "tool-not-found", hint: nil}]] = h.errors
    end

    test "a tool error keeps the last good data; the next success clears the error" do
      h =
        H.mount(
          """
          root = Stack([count, reload])
          count = Metric("Tickets", @Count(tickets.rows))
          reload = Button("Reload", @Run(tickets))
          tickets = Query("listTickets", {}, {rows: []})
          """,
          tools: %{"listTickets" => %{"rows" => [1, 2]}}
        )

      h = h |> H.put_tool("listTickets", {:error, "db down"}) |> H.click("reload")
      assert count(h) == 2

      assert [[%{code: "tool-error", message: "Query \"listTickets\" failed: db down"}]] =
               h.errors

      h = h |> H.put_tool("listTickets", {:error, {:mcp_error, "nope"}}) |> H.click("reload")
      assert [_, [%{code: "mcp-error"}]] = h.errors

      h = h |> H.put_tool("listTickets", %{"rows" => [1]}) |> H.click("reload")
      assert count(h) == 1
      assert List.last(h.errors) == []
    end

    test "an error stays until the fetch for new args settles, so recovery is not signalled early" do
      h = H.mount(@filter, tools: %{"listTickets" => {:error, "down"}})
      h = h |> H.put_tool("listTickets", :hold) |> H.input("filter", "closed")
      assert H.error_codes(h) == ["tool-error"]
      assert length(h.errors) == 1

      [ref] = H.pending_refs(h)
      h = H.deliver(h, ref, {:ok, %{"rows" => []}})
      assert [[_], []] = h.errors
    end

    test "a missing tool keeps failing quietly as args change" do
      h = H.mount(@filter, tools: %{})
      h = h |> H.input("filter", "closed") |> H.input("filter", "x")
      assert length(h.calls) == 3
      assert [[%{code: "tool-not-found"}]] = h.errors
    end

    test "an unchanged error list is not emitted again" do
      h =
        H.mount(
          """
          root = Stack([reload])
          reload = Button("Reload", @Run(tickets))
          tickets = Query("listTickets", {}, {rows: []})
          """,
          tools: %{"listTickets" => {:error, "down"}}
        )

      h = h |> H.click("reload") |> H.click("reload")
      assert length(h.errors) == 1
      assert length(h.calls) == 3
    end
  end

  describe "concurrency" do
    @many """
    root = Stack([Text("x")])
    a = Query("a", {}, null)
    b = Query("b", {}, null)
    c = Query("c", {}, null)
    """

    test "calls past the cap wait, and start as results arrive" do
      h = H.mount(@many, max_concurrency: 2, tools: %{"a" => :hold, "b" => :hold, "c" => :hold})
      assert H.call_names(h) == ["a", "b"]

      [a, _b] = H.pending_refs(h)
      h = H.deliver(h, a, {:ok, 1})
      assert H.call_names(h) == ["a", "b", "c"]
      assert length(H.pending_refs(h)) == 2
    end

    test "a cap of one runs calls one after another" do
      h = H.mount(@many, max_concurrency: 1, tools: %{"a" => 1, "b" => 2, "c" => 3})
      assert H.call_names(h) == ["a", "b", "c"]
      ctx = Runtime.eval_ctx(h.rt)
      assert Enum.map(~w(a b c), ctx.resolve_ref) == [1, 2, 3]
    end
  end
end
