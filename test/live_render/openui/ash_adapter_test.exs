defmodule LiveRender.OpenUI.AshAdapterTest do
  # Tickets live in private ETS tables owned by the test process, so tests stay isolated.
  use ExUnit.Case, async: true

  # Ash logs every ETS write at debug level.
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias LiveRender.OpenUI.{Conformance, Runtime, ToolHost}
  alias LiveRender.Test.Support.{Comment, Ticket}
  alias LiveRender.Test.SupportTools, as: Tools

  @agent %{id: "agent-1", role: :agent}
  @other_agent %{id: "agent-2", role: :agent}
  @viewer %{id: "viewer-1", role: :viewer}

  defp ctx(actor \\ @agent, tenant \\ "org1"), do: %{actor: actor, tenant: tenant}

  defp call(name, args, context \\ ctx()), do: ToolHost.call(Tools, name, args, context)

  defp seed!(title, opts \\ []) do
    owner = Keyword.get(opts, :owner, @agent)
    tenant = Keyword.get(opts, :tenant, "org1")
    ash_opts = [actor: owner, tenant: tenant, authorize?: false]

    ticket =
      Ticket
      |> Ash.Changeset.for_create(
        :create,
        %{title: title, internal_notes: "internal", secret_token: "s3cret"},
        ash_opts
      )
      |> Ash.create!()

    if opts[:closed],
      do: ticket |> Ash.Changeset.for_update(:close, %{}, ash_opts) |> Ash.update!(),
      else: ticket
  end

  defp fetch!(id, tenant \\ "org1"), do: Ash.get!(Ticket, id, tenant: tenant, authorize?: false)

  describe "descriptors" do
    test "list exactly the declared tools" do
      assert ToolHost.names(Tools, ctx()) == [
               "listTickets",
               "pagedTickets",
               "ticketList",
               "ticketByTitle",
               "createTicket",
               "closeTicket",
               "renameTicket",
               "deleteTicket",
               "openTicketCount",
               "echo"
             ]
    end

    test "derive input schemas from the action's public inputs" do
      tools = Map.new(Tools.tools(ctx()), &{&1.name, &1})

      list = tools["listTickets"]
      assert list.description == "Tickets, filtered by status"

      assert list.input_schema == %{
               "type" => "object",
               "additionalProperties" => false,
               "properties" => %{"status" => %{"type" => "string", "enum" => ["open", "closed"]}}
             }

      create = tools["createTicket"].input_schema
      assert create["required"] == ["title"]

      assert create["properties"]["title"] == %{
               "type" => "string",
               "maxLength" => 120,
               "description" => "A short summary"
             }

      assert create["properties"]["priority"] == %{
               "type" => "integer",
               "minimum" => 1,
               "maximum" => 5
             }

      # Private attributes, private arguments and the tenant attribute are not inputs.
      assert Map.keys(create["properties"]) |> Enum.sort() == [
               "priority",
               "secret_token",
               "title"
             ]

      close = tools["closeTicket"].input_schema
      assert close["required"] == ["id"]
      assert close["properties"]["id"]["format"] == "uuid"

      assert tools["pagedTickets"].input_schema["properties"]["limit"] == %{
               "type" => "integer",
               "minimum" => 1,
               "maximum" => 2
             }

      echo = tools["echo"].input_schema
      assert echo["required"] == ["message"]

      assert tools["openTicketCount"].input_schema["properties"]["min_priority"]["type"] ==
               "integer"
    end
  end

  describe "allowlist" do
    test "an undeclared tool is not found, even when the action exists" do
      assert {:error, {:tool_not_found, names}} = call("hiddenUpdate", %{})
      assert "listTickets" in names

      assert {:error, {:tool_not_found, _}} = call("read", %{})
      assert {:error, {:tool_not_found, _}} = Tools.call_tool("Ticket.read", %{}, ctx())
    end

    test "a non-public action cannot be declared" do
      assert_raise ArgumentError, ~r/action :hidden_update is not public/, fn ->
        compile_tools(quote(do: tool("x", LiveRender.Test.Support.Ticket, :hidden_update)))
      end
    end

    test "declarations are checked at compile time" do
      for {decl, message} <- [
            {quote(do: tool("x", LiveRender.Test.Support.Ticket, :nope)),
             ~r/has no action :nope/},
            {quote(do: tool("x", String, :read)), ~r/is not an Ash resource/},
            {quote(do: tool("x", LiveRender.Test.Support.Ticket, :list, fields: [:secret_token])),
             ~r/private or sensitive/},
            {quote(do: tool("x", LiveRender.Test.Support.Ticket, :list, load: [:hidden_calc])),
             ~r/is not public/},
            {quote(do: tool("x", LiveRender.Test.Support.Ticket, :create, limit: 5)),
             ~r/apply to read actions only/},
            {quote(do: tool("x", LiveRender.Test.Support.Ticket, :list, filter: "anything")),
             ~r/unknown options \[:filter\]/}
          ] do
        assert_raise ArgumentError, message, fn -> compile_tools(decl) end
      end
    end
  end

  describe "read" do
    test "passes action arguments and returns rows of public, non-sensitive fields" do
      open = seed!("Printer on fire")
      seed!("Old issue", closed: true)

      Comment
      |> Ash.Changeset.for_create(
        :create,
        %{body: "On it", author_email: "a@example.com", ticket_id: open.id},
        tenant: "org1"
      )
      |> Ash.create!()

      assert {:ok, %{"rows" => [row]}} = call("listTickets", %{"status" => "open"})

      assert row["title"] == "Printer on fire"
      assert row["status"] == "open"
      assert row["owner_id"] == "agent-1"
      assert row["shout"] == "Printer on fire!"
      assert row["comment_count"] == 1
      assert [%{"body" => "On it"} = comment] = row["comments"]

      refute Map.has_key?(row, "internal_notes")
      refute Map.has_key?(row, "secret_token")
      refute Map.has_key?(row, "hidden_calc")
      refute Map.has_key?(comment, "author_email")

      assert {:ok, %{"rows" => rows}} = call("listTickets", %{})
      assert length(rows) == 2
    end

    test "invalid arguments are reported per field" do
      assert {:error, "invalid input: status: " <> _} = call("listTickets", %{"status" => "nope"})
    end

    test "drops keys the action does not accept, so no filter or sort can be injected" do
      seed!("A")
      seed!("B", closed: true)

      assert {:ok, %{"rows" => rows}} =
               call("listTickets", %{
                 "filter" => %{"title" => "A"},
                 "sort" => "title",
                 "limit" => 1
               })

      assert length(rows) == 2
    end

    test "pagination only through declared options, capped by :limit" do
      for t <- ~w(a b c), do: seed!(t)

      assert {:ok, %{"rows" => rows, "hasMore" => true, "limit" => 2, "offset" => 0}} =
               call("pagedTickets", %{})

      assert [%{"id" => _, "title" => _} = row, _] = rows
      assert map_size(row) == 2

      assert {:ok, %{"rows" => [_, _], "limit" => 2}} = call("pagedTickets", %{"limit" => 50})

      assert {:ok, %{"rows" => [_], "hasMore" => false}} =
               call("pagedTickets", %{"offset" => 2})
    end

    test "result: :list and get? actions" do
      seed!("Only one")
      assert {:ok, [%{"title" => "Only one"}]} = call("ticketList", %{})

      assert {:ok, %{"title" => "Only one"}} = call("ticketByTitle", %{"title" => "Only one"})
      assert {:ok, nil} = call("ticketByTitle", %{"title" => "Missing"})
    end
  end

  describe "create, update, destroy" do
    test "create sets owner and tenant from the host, never from the program" do
      args = %{
        "title" => "New",
        "priority" => 2,
        "org_id" => "org2",
        "owner_id" => "attacker",
        "internal_notes" => "from the model",
        "internal_flag" => true
      }

      assert {:ok, ticket} = call("createTicket", args)
      assert ticket["title"] == "New"
      assert ticket["priority"] == 2
      assert ticket["org_id"] == "org1"
      assert ticket["owner_id"] == "agent-1"
      refute Map.has_key?(ticket, "secret_token")

      stored = fetch!(ticket["id"])
      assert stored.internal_notes == nil
      assert stored.org_id == "org1"
    end

    test "invalid input lists field errors" do
      assert {:error, message} = call("createTicket", %{"priority" => 9})
      assert message =~ "invalid input: "
      assert message =~ "title: is required"
      assert message =~ "priority: must be less than or equal to 5"
      refute message =~ "Bread Crumbs"
    end

    test "update locates the record by primary key and applies the action" do
      ticket = seed!("Jammed")

      assert {:ok, %{"id" => id, "status" => "closed"}} =
               call("closeTicket", %{"id" => ticket.id})

      assert id == ticket.id
      assert fetch!(ticket.id).status == :closed

      assert {:ok, %{"title" => "Unjammed"}} =
               call("renameTicket", %{"id" => ticket.id, "title" => "Unjammed"})
    end

    test "update without a key, or with an unknown key, fails cleanly" do
      assert {:error, "invalid input: id: is required"} = call("closeTicket", %{})
      assert {:error, "not found"} = call("closeTicket", %{"id" => Ash.UUID.generate()})
      assert {:error, "not found"} = call("closeTicket", %{"id" => "not-a-uuid"})
    end

    test "destroy returns the destroyed record" do
      ticket = seed!("Duplicate")
      assert {:ok, %{"title" => "Duplicate"}} = call("deleteTicket", %{"id" => ticket.id})
      assert {:error, _} = Ash.get(Ticket, ticket.id, tenant: "org1", authorize?: false)
    end
  end

  describe "generic actions" do
    test "run with the host's actor and tenant" do
      seed!("a")
      seed!("b")
      seed!("c", closed: true)
      seed!("other org", tenant: "org2")

      assert {:ok, 2} = call("openTicketCount", %{})
      assert {:ok, %{"message" => "hi"}} = call("echo", %{"message" => "hi"})
      assert {:error, "invalid input: message: is required"} = call("echo", %{})
      assert {:error, "forbidden"} = call("echo", %{"message" => "hi"}, ctx(nil))
    end
  end

  describe "authorization" do
    test "policies see the host's actor" do
      ticket = seed!("Mine")

      assert {:error, "forbidden"} = call("createTicket", %{"title" => "x"}, ctx(@viewer))
      assert {:error, "forbidden"} = call("closeTicket", %{"id" => ticket.id}, ctx(@other_agent))
      assert {:error, "forbidden"} = call("deleteTicket", %{"id" => ticket.id}, ctx(@viewer))
      assert {:error, "forbidden"} = call("listTickets", %{}, ctx(nil))
      assert {:error, "forbidden"} = call("listTickets", %{}, %{tenant: "org1"})

      assert fetch!(ticket.id).status == :open
    end

    test "tenants are isolated" do
      mine = seed!("org1 ticket")
      theirs = seed!("org2 ticket", tenant: "org2")

      assert {:ok, %{"rows" => [%{"title" => "org1 ticket"}]}} = call("listTickets", %{})

      assert {:ok, %{"rows" => [%{"title" => "org2 ticket"}]}} =
               call("listTickets", %{}, ctx(@agent, "org2"))

      assert {:error, "not found"} = call("closeTicket", %{"id" => theirs.id})
      assert {:error, "not found"} = call("deleteTicket", %{"id" => theirs.id})
      assert fetch!(theirs.id, "org2").status == :open
      assert fetch!(mine.id).status == :open
    end

    test "a missing tenant is an error, not a cross-tenant read" do
      seed!("x")

      assert {:error, "invalid input: a tenant is required"} =
               call("listTickets", %{}, %{actor: @agent})
    end
  end

  test "unexpected failures do not raise or leak details" do
    log =
      capture_log(fn ->
        assert {:error, "internal error"} =
                 LiveRender.OpenUI.AshAdapter.call(
                   [%{broken_tool() | action: :missing}],
                   "broken",
                   %{},
                   ctx()
                 )
      end)

    assert log =~ "OpenUI tool broken failed"
  end

  describe "end to end with the runtime" do
    @program """
    $title = "Printer on fire"
    root = Stack([count, create])
    tickets = Query("listTickets", {status: "open"}, {rows: []})
    newTicket = Mutation("createTicket", {title: $title})
    count = Metric("Open tickets", @Count(tickets.rows))
    create = Button("Create", Action([@Run(newTicket), @Run(tickets)]))
    """

    test "a Query lists records and @Run of a Mutation creates one" do
      seed!("Existing")
      seed!("Other org", tenant: "org2")

      rt = mount(ctx())
      assert metric(rt) == 1

      {rt, _} = run(Runtime.click_statement(rt, "create"), ctx())

      assert %{"status" => "success", "data" => %{"title" => "Printer on fire"}} =
               Runtime.mutation(rt, "newTicket")

      assert metric(rt) == 2

      titles =
        Ticket
        |> Ash.read!(tenant: "org1", authorize?: false)
        |> Enum.map(& &1.title)
        |> Enum.sort()

      assert titles == ["Existing", "Printer on fire"]
    end

    test "a denied mutation becomes a tool error and changes nothing" do
      seed!("Existing")
      rt = mount(ctx(@viewer))
      assert metric(rt) == 1

      {rt, _} = run(Runtime.click_statement(rt, "create"), ctx(@viewer))

      assert %{"status" => "error"} = Runtime.mutation(rt, "newTicket")

      assert Enum.any?(
               Runtime.errors(rt),
               &(&1.code == "tool-error" and &1.message =~ "forbidden")
             )

      assert metric(rt) == 1
    end

    defp mount(context) do
      Conformance.library()
      |> Runtime.new(response: @program, streaming: false)
      |> Runtime.start()
      |> run(context)
      |> elem(0)
    end

    defp metric(rt), do: hd(Runtime.tree(rt).props["children"]).props["value"]

    # Executes effects synchronously, the way the conformance runner does.
    defp run({rt, effects}, context) do
      Enum.reduce(effects, {rt, []}, fn
        {:call_tool, ref, name, args}, {rt, _} ->
          run(Runtime.tool_result(rt, ref, ToolHost.call(Tools, name, args, context)), context)

        _effect, acc ->
          acc
      end)
    end
  end

  defp broken_tool do
    hd(Tools.__live_render_ash_tools__()) |> Map.put(:name, "broken")
  end

  defp compile_tools(declaration) do
    name = Module.concat(__MODULE__, "Tools#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(name) do
          use LiveRender.OpenUI.AshAdapter
          unquote(declaration)
        end
      end
    )
  end
end
