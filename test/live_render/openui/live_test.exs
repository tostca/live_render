defmodule LiveRender.OpenUI.LiveTest do
  @moduledoc """
  Drives `LiveRender.OpenUI.Live` through real LiveView events: rendering, two-way binding, form
  events, async tools, streaming, edit mode, render-error containment, and the official level 2
  fixtures replayed through the DOM.
  """
  use ExUnit.Case, async: true

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias LiveRender.OpenUI.{Conformance, TestHostLive}

  @endpoint LiveRender.OpenUI.TestEndpoint

  defp mount_program(program, opts \\ []) do
    session =
      %{
        "program" => program,
        "streaming" => Keyword.get(opts, :streaming, false),
        "edit_base" => opts[:edit_base],
        "library" => Keyword.get(opts, :library, "standard"),
        "tools" => opts[:tools],
        "test_pid" => self()
      }

    {:ok, view, html} = live_isolated(build_conn(), TestHostLive, session: session)
    {view, html}
  end

  defp tool_agent(results) do
    start_supervised!({Agent, fn -> %{results: results, calls: []} end})
  end

  defp messages do
    receive do
      {:openui_msg, message} -> [message | messages()]
    after
      50 -> []
    end
  end

  defp events, do: for({:event, e} <- messages(), do: e)

  describe "rendering" do
    test "renders native components without freezing nodes" do
      {_view, html} =
        mount_program("""
        root = Stack([Heading("Orders", "h1"), Card("Today", [Metric("Open", 3), Tag("live", "green")])])
        """)

      assert html =~ "Orders"
      assert html =~ "Today"
      assert html =~ "Open"
      assert html =~ ">3<"
      refute html =~ ~s(phx-update="ignore")
    end

    test "escapes text from the program" do
      {_view, html} = mount_program(~s|root = Stack([Text("<script>alert(1)</script>")])|)
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "unsafe link URLs do not become hrefs" do
      {_view, html} = mount_program(~s|root = Stack([Link("x", "javascript:alert(1)")])|)
      refute html =~ "javascript:"
    end
  end

  describe "state" do
    test "typing into a bound input re-renders dependent text" do
      {view, _} =
        mount_program("""
        $q = ""
        root = Stack([search, Text("You typed: " + $q)])
        search = Input("search", "Search", null, $q)
        """)

      html = view |> form("form", %{"value" => "late"}) |> render_change()
      assert html =~ "You typed: late"
      assert_receive {:openui_msg, {:state, %{"$q" => "late"}}}

      # State survives a re-render triggered elsewhere.
      html = render(view)
      assert html =~ "You typed: late"
    end

    test "node ids stay stable across re-renders and streamed growth" do
      program = "root = Stack([Input(\"a\", \"A\"), more])\n"
      {view, html} = mount_program(program, streaming: true)
      [id] = Regex.run(~r/id="(ui-n-children-0-input)"/, html, capture: :all_but_first)

      send(view.pid, {:set_program, program <> "more = Text(\"later\")\n", false})
      html = render(view)
      assert html =~ "later"
      assert html =~ ~s(id="#{id}")
    end

    test "a button inside a form sends form state with its event" do
      {view, _} =
        mount_program("""
        root = Stack([Form("contact", [Input("email", "Email"), send])])
        send = Button("Send", @ToAssistant("Send"))
        """)

      view |> form("form", %{"value" => "a@b.co"}) |> render_change()
      view |> element("button", "Send") |> render_click()

      assert [event] = events()
      assert event["type"] == "continue_conversation"
      assert event["formName"] == "contact"

      assert event["formState"] == %{
               "contact" => %{"email" => %{"value" => "a@b.co", "componentType" => "input"}}
             }
    end

    test "validation rules block a form's actions until fields pass" do
      {view, _} =
        mount_program("""
        root = Stack([Form("f", [Input("email", "Email", null, null, "email", {required: true, email: true}), go])])
        go = Button("Go", @ToAssistant("Go"))
        """)

      html = view |> element("button", "Go") |> render_click()
      assert html =~ "This field is required"
      assert events() == []

      view |> form("form", %{"value" => "nope"}) |> render_change()
      html = view |> element("button", "Go") |> render_click()
      assert html =~ "Please enter a valid email"

      html = view |> form("form", %{"value" => "a@b.co"}) |> render_change()
      refute html =~ "Please enter a valid email"
      view |> element("button", "Go") |> render_click()
      assert [%{"humanFriendlyMessage" => "Go"}] = events()
    end
  end

  test "a secondary button inside a form is not blocked by the form's validation" do
    {view, _} =
      mount_program("""
      root = Stack([Form("f", [Input("email", "Email", null, null, "email", {required: true}), go, ask])])
      go = Button("Go", @ToAssistant("Go"))
      ask = Button("Ask", @ToAssistant("Ask"), "secondary")
      """)

    view |> element("button", "Ask") |> render_click()
    assert [%{"humanFriendlyMessage" => "Ask"}] = events()

    view |> element("button", "Go") |> render_click()
    assert events() == []
  end

  describe "tools" do
    test "a query runs asynchronously after mount and its result renders" do
      agent = tool_agent(%{"countTickets" => %{"open" => 7}})

      {view, html} =
        mount_program(
          """
          root = Stack([Metric("Open", stats.open)])
          stats = Query("countTickets", {}, {open: 0})
          """,
          tools: agent
        )

      assert html =~ ">0<"
      assert render_async(view) =~ ">7<"
      assert [%{"tool" => "countTickets"}] = Agent.get(agent, & &1.calls)
    end

    test "no tool runs while streaming; the query runs when the stream ends" do
      agent = tool_agent(%{"countTickets" => %{"open" => 5}})

      {view, _} =
        mount_program(
          ~s|root = Stack([Metric("Open", stats.open)])\nstats = Query("countTickets", {}, {open: 0})\n|,
          tools: agent,
          streaming: true
        )

      render_async(view)
      assert Agent.get(agent, & &1.calls) == []

      send(view.pid, {:set_program, render_program(view), false})
      assert render_async(view) =~ ">5<"
      assert length(Agent.get(agent, & &1.calls)) == 1
    end

    test "a missing tool reports tool-not-found and nothing crashes" do
      {view, _} =
        mount_program(
          """
          $title = "Bug"
          root = Stack([Button("Create", Action([@Run(make), @ToAssistant("Created")]))])
          make = Mutation("createTicket", {title: $title})
          """,
          tools: tool_agent(%{"other" => 1})
        )

      view |> element("button", "Create") |> render_click()
      render_async(view)
      received = messages()
      assert for({:event, e} <- received, do: e) == []
      assert [errors | _] = for({:errors, list} <- Enum.reverse(received), do: list)
      assert Enum.any?(errors, &(&1.code == "tool-not-found" and &1.hint =~ "other"))
    end
  end

  describe "streaming" do
    test "renders progressively and keeps user state while later chunks arrive" do
      {view, html} =
        mount_program(~s|$name = ""\nroot = Stack([field, Text("Hi " + $name)])\n|,
          streaming: true
        )

      assert html =~ "Hi "

      send(
        view.pid,
        {:set_program,
         "$name = \"\"\nroot = Stack([field, Text(\"Hi \" + $name)])\nfield = Input(\"name\", \"Name\", null, $name)\n",
         true}
      )

      view |> form("form", %{"value" => "Ada"}) |> render_change()

      send(
        view.pid,
        {:set_program,
         "$name = \"\"\nroot = Stack([field, Text(\"Hi \" + $name)])\nfield = Input(\"name\", \"Name\", null, $name)\n",
         false}
      )

      assert render(view) =~ "Hi Ada"
    end
  end

  describe "edit mode" do
    test "the base renders until the patch has finished streaming, then the merge renders" do
      base = """
      root = Stack([a, b])
      a = Text("A")
      b = Text("B")
      """

      {view, html} = mount_program("a = Text(\"A2", edit_base: base, streaming: true)
      assert html =~ ">A<"
      refute html =~ ">A2<"

      send(view.pid, {:set_program, "a = Text(\"A2\")\nc = Text(\"C\")\n", false})
      html = render(view)
      assert html =~ ">A2<"
      assert html =~ ">B<"
      refute html =~ ">C<"
      assert_receive {:openui_msg, {:program, merged}}
      assert merged =~ ~s|a = Text("A2")|
    end
  end

  describe "value types" do
    @typed """
    $x = null
    root = Stack([Input("x", "X", null, $x), Text("[" + $x + "]")])
    """

    defp change(view, params) do
      node =
        view
        |> element("form input[name=node]")
        |> render()
        |> then(&Regex.run(~r/value="([^"]*)"/, &1))
        |> List.last()

      view |> element("form") |> render_change(Map.put(params, "node", node))
    end

    test "list keeps the chosen values and drops blanks; nothing chosen is an empty list" do
      {view, _html} = mount_program(@typed)
      assert change(view, %{"value" => ["", "a", "b"], "type" => "list"}) =~ "[a,b]"
      assert change(view, %{"type" => "list"}) =~ "[]"
    end

    test "joined joins the chosen values with commas" do
      {view, _html} = mount_program(@typed)

      assert change(view, %{"value" => ["2026-01-01", "2026-01-31"], "type" => "joined"}) =~
               "[2026-01-01,2026-01-31]"

      assert change(view, %{"value" => ["", "2026-01-31"], "type" => "joined"}) =~ "[2026-01-31]"
    end
  end

  describe "render errors" do
    test "a renderer that raises is contained, keeps its last good render, and is reported" do
      program = fn explode ->
        "$x = #{explode}\nroot = Stack([Text(\"ok\"), Boom($x), Checkbox(\"x\", \"Explode\", $x)])\n"
      end

      {view, html} = mount_program(program.(false), library: "boom")
      assert html =~ "calm"

      # Checking the box makes Boom's renderer raise on the next render.
      html = view |> form("form", %{"value" => "true", "type" => "boolean"}) |> render_change()
      assert html =~ "ok"
      assert html =~ "calm"
      received = messages()
      assert [errors | _] = for({:errors, list} <- Enum.reverse(received), do: list)
      assert Enum.any?(errors, &(&1.code == "render-error" and &1.component == "Boom"))

      # Recovery is signalled with an empty list.
      view |> form("form", %{"value" => "false", "type" => "boolean"}) |> render_change()
      assert {:errors, []} in messages()
    end
  end

  # ── Level 2 fixtures through the DOM ───────────────────────────────────

  for id <- Conformance.cases(), Conformance.interaction_case?(id) do
    @id id
    test "level 2 through LiveView: #{id}" do
      files = Conformance.files(@id)

      %{"interactions" => steps, "expected" => expected} =
        Jason.decode!(files["interactions.json"])

      {initial, steps} = Enum.split_while(steps, &Map.has_key?(&1, "tool"))
      agent = tool_agent(Map.new(initial, &{&1["tool"], &1["result"]}))

      {view, _} = mount_program(files["input.oui"], library: "fixtures", tools: agent)
      render_async(view)

      for step <- steps do
        case step do
          %{"tool" => name, "result" => result} ->
            Agent.update(agent, fn s -> put_in(s.results[name], result) end)

          %{"click" => sid} ->
            view |> element(~s|button[data-statement="#{sid}"]|) |> render_click()
            render_async(view)

          %{"type" => [sid, text]} ->
            view
            |> form(~s|[data-statement="#{sid}"] form|, %{"value" => text})
            |> render_change()

            render_async(view)
        end
      end

      got = events()
      want = expected["events"] || []
      assert length(got) == length(want), "events: #{inspect(got)}"

      for {w, e} <- Enum.zip(want, got), {k, v} <- w do
        assert Map.get(e, k) == v, "event #{k}: expected #{inspect(v)}, got #{inspect(e)}"
      end

      if calls = expected["toolCalls"] do
        actual = agent |> Agent.get(& &1.calls) |> Enum.chunk_by(& &1) |> Enum.map(&hd/1)
        assert actual == calls
      end
    end
  end

  defp render_program(_view) do
    "root = Stack([Metric(\"Open\", stats.open)])\nstats = Query(\"countTickets\", {}, {open: 0})\n"
  end
end
