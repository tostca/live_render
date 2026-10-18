defmodule LiveRender.OpenUI.ScenariosTest do
  @moduledoc """
  The end-to-end acceptance scenarios of the OpenUI 1.0 handoff (section 9), driven through a
  LiveView host. Scenario B (authorized ticket workflow) lives with the Ash adapter tests.
  """
  use ExUnit.Case, async: true

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias LiveRender.OpenUI.{Parser, Protocol, StandardLibrary, TestHostLive}

  @endpoint LiveRender.OpenUI.TestEndpoint

  defp mount_program(program, opts \\ []) do
    session = %{
      "program" => program,
      "streaming" => Keyword.get(opts, :streaming, false),
      "edit_base" => opts[:edit_base],
      "library" => "standard",
      "tools" => opts[:tools],
      "test_pid" => self()
    }

    {:ok, view, html} = live_isolated(build_conn(), TestHostLive, session: session)
    {view, html}
  end

  defp messages do
    receive do
      {:openui_msg, message} -> [message | messages()]
    after
      50 -> []
    end
  end

  @dashboard """
  root = Stack([title, filters, kpis, table])
  title = Heading("Support dashboard", "h1")
  $status = "open"
  filters = Form("filters", [Select("status", [SelectItem("open", "Open"), SelectItem("closed", "Closed")], "Status", $status)])
  kpis = Card("Tickets", [Metric("Matching", @Count(shown)), Metric("Total", @Count(tickets))])
  shown = @Filter(tickets, "status", "==", $status)
  table = Table([Col("Title", shown.title), Col("Status", shown.status)])
  tickets = [{title: "Login fails", status: "open"}, {title: "Typo", status: "closed"}, {title: "Slow page", status: "open"}]
  """

  test "A: a streamed dashboard renders progressively, ends equal to a batch parse, and filters locally" do
    # Arbitrary chunk boundaries, including inside strings and names.
    chunks = for <<chunk::binary-size(17) <- @dashboard>>, do: chunk

    rest =
      binary_part(@dashboard, length(chunks) * 17, byte_size(@dashboard) - length(chunks) * 17)

    chunks = chunks ++ [rest]

    {view, _} = mount_program(hd(chunks), streaming: true)

    Enum.reduce(tl(chunks), hd(chunks), fn chunk, text ->
      text = text <> chunk
      send(view.pid, {:set_program, text, true})
      # Every frame is a valid page.
      assert render(view) =~ ~s(data-openui-root)
      text
    end)

    send(view.pid, {:set_program, @dashboard, false})
    html = render(view)
    assert html =~ "Support dashboard"
    assert html =~ "Login fails"
    refute html =~ "Typo"

    batch = Parser.parse(@dashboard, StandardLibrary.library())
    assert batch.errors == []

    # The user changes the filter: values update with no model request and no tool call.
    html = view |> form(~s|form[id$="-form"]|, %{"value" => "closed"}) |> render_change()
    assert html =~ "Typo"
    refute html =~ "Login fails"
    assert {:state, %{"$status" => "closed"}} in messages()
  end

  test "C: a follow-up button sends its message, context and form values; the host builds the next turn" do
    {view, _} =
      mount_program("""
      root = Stack([Form("order", [Input("note", "Note"), ask])])
      ask = Button("Ask", @ToAssistant("Explain the delay", {orderId: 42}))
      """)

    view |> form("form", %{"value" => "rush"}) |> render_change()
    view |> element("button", "Ask") |> render_click()

    assert [event] = for({:event, e} <- messages(), do: e)
    assert event["params"] == %{"context" => %{"orderId" => 42}}

    assert event["formState"] == %{
             "order" => %{"note" => %{"value" => "rush", "componentType" => "input"}}
           }

    stored =
      Protocol.user_turn(
        event["humanFriendlyMessage"],
        event["formState"],
        event["params"]["context"]
      )

    assert stored =~ "]]>openui:context"

    model_text = Protocol.user_turn_for_model(stored)
    refute model_text =~ "]]>openui:"
    assert model_text =~ "Explain the delay\ncontext and form values = "
    assert model_text =~ ~s("orderId":42)
  end

  test "D: an edit merges after streaming, keeps unrelated statements and user state, and prunes orphans" do
    stored =
      Protocol.build(
        content: """
        root = Stack([chart, notes])
        $period = "monthly"
        chart = Card("Revenue " + $period, [Text("chart")])
        notes = Input("notes", "Notes", null, $notes)
        legend = Text("old legend")
        """,
        attributes: %{"library" => "live_render@0.5.0"},
        end: true
      )

    program = Protocol.parse(stored).content
    {view, html} = mount_program(program)
    assert html =~ "Revenue monthly"

    view |> form("form", %{"value" => "keep me"}) |> render_change()

    patch = """
    Switching to weekly.
    ```openui
    $period = "weekly"
    legend = null
    ```
    """

    # The patch streams: the current program keeps rendering, unmerged.
    send(view.pid, {:edit, program, binary_part(patch, 0, 40), true})
    assert render(view) =~ "Revenue monthly"

    send(view.pid, {:edit, program, patch, false})
    html = render(view)
    assert html =~ "Revenue weekly"
    assert html =~ ~s(value="keep me")

    assert_receive {:openui_msg, {:program, merged}}
    refute merged =~ "legend"
    assert merged =~ ~s($period = "weekly")
    assert merged =~ "notes = Input("
  end

  test "E: one invalid component, an unknown function and a missing tool are reported; the rest renders" do
    {view, html} =
      mount_program(
        """
        root = Stack([Text("still here"), chart, Text(@Nope(1) == null ? "fallback" : "x"), Metric("Rows", stats.n)])
        chart = Chart([1, 2, 3])
        stats = Query("missingTool", {}, {n: 0})
        """,
        tools: start_supervised!({Agent, fn -> %{results: %{"other" => 1}, calls: []} end})
      )

    assert html =~ "still here"
    assert html =~ "fallback"

    render_async(view)
    assert render(view) =~ "still here"

    codes =
      for {:errors, list} <- messages(), e <- list, do: e.code

    assert "unknown-component" in codes
    assert "unknown-function" in codes
    assert "tool-not-found" in codes
  end
end
