defmodule LiveRender.OpenUI.ToolHostTest do
  @moduledoc "Host-owned tools (language.md, section 6.4)."

  use ExUnit.Case, async: true

  alias LiveRender.OpenUI.ToolHost

  defmodule Tickets do
    @behaviour LiveRender.OpenUI.ToolAdapter

    @impl true
    def tools(%{role: :admin}), do: [%{name: "listTickets", description: "All"}, "deleteTicket"]
    def tools(_context), do: [%{"name" => "listTickets", "inputSchema" => %{"type" => "object"}}]

    @impl true
    def call_tool("listTickets", args, context),
      do: {:ok, %{"args" => args, "actor" => context[:actor], "tenant" => context[:tenant]}}

    def call_tool("deleteTicket", _args, _context), do: :ok
  end

  defmodule Faulty do
    @behaviour LiveRender.OpenUI.ToolAdapter

    @impl true
    def tools(_), do: ["raise", "exit", "throw", "bare", "unhandled"]

    @impl true
    def call_tool("raise", _, _), do: raise(ArgumentError, "bad input")
    def call_tool("exit", _, _), do: exit(:boom)
    def call_tool("throw", _, _), do: throw(:ball)
    def call_tool("bare", args, _), do: [args]
  end

  defmodule Broken do
    def tools(_), do: raise("listing failed")
  end

  defmodule Exiting do
    def tools(%{throw: true}), do: throw(:no_tools)
    def tools(_), do: exit(:down)
  end

  describe "map sources" do
    test "call 1- and 2-arity functions" do
      tools = %{
        "echo" => fn args -> {:ok, args} end,
        "who" => fn _args, ctx -> {:ok, ctx.actor} end
      }

      assert ToolHost.call(tools, "echo", %{"a" => 1}) == {:ok, %{"a" => 1}}
      assert ToolHost.call(tools, "who", %{}, %{actor: "ann"}) == {:ok, "ann"}
    end

    test "bare return values are wrapped; :ok means no data" do
      tools = %{
        "n" => fn _ -> 42 end,
        "ok" => fn _ -> :ok end,
        "e" => fn _ -> {:error, :nope} end
      }

      assert ToolHost.call(tools, "n", %{}) == {:ok, 42}
      assert ToolHost.call(tools, "ok", %{}) == {:ok, nil}
      assert ToolHost.call(tools, "e", %{}) == {:error, :nope}
    end

    test "atom keys name tools too" do
      tools = %{listTickets: fn _ -> {:ok, []} end}
      assert ToolHost.names(tools) == ["listTickets"]
      assert ToolHost.call(tools, "listTickets", %{}) == {:ok, []}
    end

    test "a function of the wrong arity is an error, not a crash" do
      assert {:error, msg} = ToolHost.call(%{"x" => fn -> 1 end}, "x", %{})
      assert is_binary(msg)
    end
  end

  describe "allowlist" do
    test "a name no source lists is tool_not_found with the available names" do
      tools = %{"b" => fn _ -> 1 end, "a" => fn _ -> 2 end}
      assert ToolHost.call(tools, "c", %{}) == {:error, {:tool_not_found, ["a", "b"]}}
    end

    test "names are case-sensitive" do
      assert {:error, {:tool_not_found, _}} =
               ToolHost.call(%{"listTickets" => fn _ -> 1 end}, "listtickets", %{})
    end

    test "nil means no tools" do
      assert ToolHost.names(nil) == []
      assert ToolHost.call(nil, "x", %{}) == {:error, {:tool_not_found, []}}
    end

    test "a module only runs names it lists for the context" do
      assert ToolHost.call(Tickets, "deleteTicket", %{}) ==
               {:error, {:tool_not_found, ["listTickets"]}}

      assert ToolHost.call(Tickets, "deleteTicket", %{}, %{role: :admin}) == {:ok, nil}
    end

    test "a module whose listing fails has no tools" do
      assert ToolHost.names(Broken) == []
      assert ToolHost.call(Broken, "x", %{}) == {:error, {:tool_not_found, []}}
      assert ToolHost.names(Exiting) == []
      assert ToolHost.names(Exiting, %{throw: true}) == []
      assert ToolHost.call([Exiting, %{"a" => fn _ -> 1 end}], "a", %{}) == {:ok, 1}
    end

    test "a module that is not loaded has no tools" do
      assert ToolHost.names(NoSuchModule) == []
    end
  end

  describe "module sources" do
    test "receive args and the host context" do
      assert ToolHost.call(Tickets, "listTickets", %{"s" => 1}, %{actor: "ann"}) ==
               {:ok, %{"args" => %{"s" => 1}, "actor" => "ann", "tenant" => nil}}
    end

    test "{module, extra} merges extra context over the host context" do
      source = {Tickets, %{tenant: "acme", actor: "bot"}}

      assert ToolHost.call(source, "listTickets", %{}, %{actor: "ann"}) ==
               {:ok, %{"args" => %{}, "actor" => "bot", "tenant" => "acme"}}

      assert ToolHost.names({Tickets, %{role: :admin}}) == ["listTickets", "deleteTicket"]
    end

    test "descriptors keep the metadata a tool lists" do
      assert [%{name: "listTickets", input_schema: %{"type" => "object"}}] =
               ToolHost.descriptors(Tickets)

      assert [%{name: "listTickets", description: "All"}, %{name: "deleteTicket"}] =
               ToolHost.descriptors(Tickets, %{role: :admin})
    end

    test "exceptions, exits and throws become errors" do
      assert ToolHost.call(Faulty, "raise", %{}) == {:error, "bad input"}
      assert {:error, "exited: :boom"} = ToolHost.call(Faulty, "exit", %{})
      assert {:error, "threw: :ball"} = ToolHost.call(Faulty, "throw", %{})
      assert ToolHost.call(Faulty, "bare", %{"a" => 1}) == {:ok, [%{"a" => 1}]}
      assert {:error, msg} = ToolHost.call(Faulty, "unhandled", %{})
      assert msg =~ "no function clause"
    end
  end

  describe "lists of sources" do
    test "the first source that lists a name wins" do
      first = %{"listTickets" => fn _ -> {:ok, :map} end}
      tools = [first, Tickets, %{"extra" => fn _ -> {:ok, :extra} end}]

      assert ToolHost.names(tools) == ["listTickets", "extra"]
      assert ToolHost.call(tools, "listTickets", %{}) == {:ok, :map}
      assert ToolHost.call(tools, "extra", %{}) == {:ok, :extra}

      assert ToolHost.call(tools, "nope", %{}) ==
               {:error, {:tool_not_found, ["listTickets", "extra"]}}
    end
  end

  describe "with the runtime" do
    alias LiveRender.OpenUI.RuntimeHarness, as: H

    test "a missing tool surfaces as tool-not-found with the host's names" do
      tools = [%{"b" => fn _ -> 1 end}, {Tickets, %{}}]

      h =
        H.mount(~s|root = Stack([Text("x")])\nq = Query("nope", {}, null)\n|,
          tools: %{"nope" => fn args -> ToolHost.call(tools, "nope", args) end}
        )

      assert [[%{code: "tool-not-found", hint: "Available tools: b, listTickets"}]] = h.errors
    end

    test "a tool that raises becomes a tool-error and the host keeps going" do
      h =
        H.mount(~s|root = Stack([Text("x")])\nq = Query("raise", {}, null)\n|,
          tools: %{"raise" => fn args -> ToolHost.call(Faulty, "raise", args) end}
        )

      assert [[%{code: "tool-error", message: "Query \"raise\" failed: bad input"}]] = h.errors
    end
  end
end
