# OpenUI 1.0 on Phoenix LiveView, in one file.
#
#     elixir examples/openui_demo.exs
#
# Then open http://localhost:4000. Without an API key, "Stream the sample" plays a canned model
# response chunk by chunk: the page renders progressively, the ticket query runs when the stream
# ends, the status filter refetches, the form validates and creates a ticket through a mutation,
# and button events land in the event log. With ANTHROPIC_API_KEY set, the prompt box asks a real
# model through ReqLLM.

Mix.install([
  {:phoenix_playground, "~> 0.1.6"},
  {:live_render, path: Path.expand("..", __DIR__)},
  {:req_llm, "~> 1.6"}
])

defmodule Demo.Tickets do
  @moduledoc false
  @behaviour LiveRender.OpenUI.ToolAdapter

  # Unlinked and idempotent: the playground's code reloader evaluates this file again.
  def start do
    if Process.whereis(__MODULE__), do: :ok, else: start_agent()
  end

  defp start_agent do
    Agent.start(
      fn ->
        [
          %{
            "id" => 1,
            "title" => "Login fails on Safari",
            "status" => "open",
            "priority" => "high"
          },
          %{
            "id" => 2,
            "title" => "Typo on pricing page",
            "status" => "closed",
            "priority" => "low"
          },
          %{"id" => 3, "title" => "Export times out", "status" => "open", "priority" => "medium"}
        ]
      end,
      name: __MODULE__
    )
  end

  @impl true
  def tools(_context) do
    [
      %{
        name: "listTickets",
        description: "Tickets with the given status",
        input_schema: %{"type" => "object", "properties" => %{"status" => %{"type" => "string"}}}
      },
      %{
        name: "createTicket",
        description: "Creates a ticket",
        input_schema: %{
          "type" => "object",
          "properties" => %{"title" => %{"type" => "string"}, "priority" => %{"type" => "string"}},
          "required" => ["title"]
        }
      }
    ]
  end

  @impl true
  def call_tool("listTickets", args, _context) do
    Process.sleep(300)
    rows = Agent.get(__MODULE__, & &1)

    rows =
      if args["status"] in [nil, "", "all"],
        do: rows,
        else: Enum.filter(rows, &(&1["status"] == args["status"]))

    {:ok, %{"rows" => rows}}
  end

  def call_tool("createTicket", %{"title" => title} = args, _context)
      when is_binary(title) and title != "" do
    Process.sleep(300)

    ticket =
      Agent.get_and_update(__MODULE__, fn rows ->
        t = %{
          "id" => length(rows) + 1,
          "title" => title,
          "status" => "open",
          "priority" => args["priority"] || "medium"
        }

        {t, rows ++ [t]}
      end)

    {:ok, ticket}
  end

  def call_tool("createTicket", _args, _context), do: {:error, "title is required"}
end

defmodule Demo.Live do
  use Phoenix.LiveView

  alias LiveRender.OpenUI.{Conversation, Generate, StandardLibrary}

  @sample ~S"""
  Here is your support dashboard.
  ```openui-lang
  root = Stack([header, filters, Grid([kpis, newTicket]), list])
  header = Heading("Support dashboard", "h1")
  $status = "open"
  filters = Select("status", [SelectItem("open", "Open"), SelectItem("closed", "Closed"), SelectItem("all", "All")], "Status", $status)
  tickets = Query("listTickets", {status: $status}, {rows: []})
  kpis = Card("Overview", [Metric("Tickets shown", @Count(tickets.rows)), Metric("High priority", @Count(@Filter(tickets.rows, "priority", "==", "high")))])
  list = Card("Tickets", [Table([Col("#", tickets.rows.id), Col("Title", tickets.rows.title), Col("Priority", tickets.rows.priority)])])
  $title = ""
  $priority = "medium"
  newTicket = Card("New ticket", [Form("ticket", [titleField, Select("priority", [SelectItem("low", "Low"), SelectItem("medium", "Medium"), SelectItem("high", "High")], "Priority", $priority), Stack([create, ask], "row")])])
  titleField = Input("title", "Title", "What went wrong?", $title, "text", {required: true, minLength: 3})
  create = Button("Create", Action([@Run(createTicket), @Run(tickets), @Reset($title), @ToAssistant("Created a ticket", {title: $title})]))
  ask = Button("Ask the assistant", @ToAssistant("Summarize the open tickets"), "secondary")
  createTicket = Mutation("createTicket", {title: $title, priority: $priority})
  ```
  """

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       library: StandardLibrary.library(),
       text: "",
       streaming: false,
       generation: 0,
       events: [],
       errors: [],
       conversation: Conversation.new(),
       llm?: System.get_env("ANTHROPIC_API_KEY") not in [nil, ""]
     )}
  end

  def render(assigns) do
    ~H"""
    <script src="https://cdn.tailwindcss.com">
    </script>
    <script>
      // The components use shadcn-style color tokens; map them to CSS variables.
      tailwind.config = {theme: {extend: {colors: Object.fromEntries(
        ["border", "input", "background", "foreground", "primary", "primary-foreground", "secondary",
         "secondary-foreground", "muted", "muted-foreground", "accent", "accent-foreground", "card",
         "card-foreground", "destructive", "destructive-foreground"].map((c) => [c, `hsl(var(--${c}))`]))}}}
    </script>
    <style>
      :root { --border: 220 13% 91%; --input: 220 13% 91%; --background: 0 0% 100%; --foreground: 222 47% 11%;
        --primary: 222 47% 11%; --primary-foreground: 210 40% 98%; --secondary: 210 40% 96%;
        --secondary-foreground: 222 47% 11%; --muted: 210 40% 96%; --muted-foreground: 215 16% 47%;
        --accent: 210 40% 96%; --accent-foreground: 222 47% 11%; --card: 0 0% 100%; --card-foreground: 222 47% 11%;
        --destructive: 0 72% 51%; --destructive-foreground: 210 40% 98%; }
    </style>
    <main class="mx-auto flex max-w-5xl flex-col gap-6 p-6 font-sans">
      <div class="flex flex-wrap items-center gap-3">
        <button phx-click="sample" class="rounded-md bg-black px-4 py-2 text-sm text-white">
          Stream the sample
        </button>
        <form :if={@llm?} phx-submit="ask" class="flex flex-1 gap-2">
          <input name="q" placeholder="Ask for a UI…" class="flex-1 rounded-md border px-3 py-2 text-sm" />
          <button class="rounded-md border px-4 py-2 text-sm">Ask the model</button>
        </form>
        <span :if={@streaming} class="text-sm text-gray-500">streaming…</span>
      </div>

      <.live_component
        :if={@text != ""}
        module={LiveRender.OpenUI.Live}
        id={"answer-#{@generation}"}
        library={@library}
        response={@text}
        streaming={@streaming}
        tools={Demo.Tickets}
        tool_context={%{actor: "demo-user"}}
      />

      <section :if={@events != [] or @errors != []} class="grid gap-4 md:grid-cols-2">
        <div>
          <h2 class="mb-2 font-semibold">Host events</h2>
          <pre :for={e <- @events} class="mb-2 overflow-x-auto rounded bg-gray-100 p-2 text-xs">{Jason.encode!(e, pretty: true)}</pre>
        </div>
        <div>
          <h2 class="mb-2 font-semibold">Errors</h2>
          <pre :for={e <- @errors} class="mb-2 overflow-x-auto rounded bg-red-50 p-2 text-xs">{Jason.encode!(e, pretty: true)}</pre>
        </div>
      </section>
    </main>
    """
  end

  def handle_event("sample", _params, socket) do
    chunks = for <<c::binary-size(23) <- @sample>>, do: c
    tail = binary_part(@sample, length(chunks) * 23, byte_size(@sample) - length(chunks) * 23)
    send(self(), {:chunks, chunks ++ [tail]})

    {:noreply,
     assign(socket,
       text: "",
       streaming: true,
       generation: socket.assigns.generation + 1,
       events: [],
       errors: []
     )}
  end

  def handle_event("ask", %{"q" => q}, socket) do
    Generate.stream("anthropic:claude-haiku-4-5", q,
      library: socket.assigns.library,
      conversation: socket.assigns.conversation,
      tools: Demo.Tickets,
      prompt: [inline_mode: true],
      pid: self()
    )

    conversation = Conversation.add_user(socket.assigns.conversation, q)

    {:noreply,
     assign(socket,
       conversation: conversation,
       text: "",
       streaming: true,
       generation: socket.assigns.generation + 1
     )}
  end

  def handle_info({:chunks, []}, socket), do: {:noreply, assign(socket, streaming: false)}

  def handle_info({:chunks, [c | rest]}, socket) do
    Process.send_after(self(), {:chunks, rest}, 40)
    {:noreply, update(socket, :text, &(&1 <> c))}
  end

  def handle_info({:live_render, :openui_chunk, chunk}, socket),
    do: {:noreply, update(socket, :text, &(&1 <> chunk))}

  def handle_info({:live_render, :openui_done, text}, socket) do
    conversation =
      Conversation.add_assistant(socket.assigns.conversation, text,
        library: socket.assigns.library
      )

    {:noreply, assign(socket, text: text, streaming: false, conversation: conversation)}
  end

  def handle_info({:live_render, :error, reason}, socket),
    do: {:noreply, assign(socket, streaming: false, errors: [%{"error" => inspect(reason)}])}

  def handle_info({:openui, _id, {:event, event}}, socket),
    do: {:noreply, update(socket, :events, &[event | &1])}

  def handle_info({:openui, _id, {:errors, errors}}, socket),
    do: {:noreply, assign(socket, errors: errors)}

  def handle_info({:openui, _id, _other}, socket), do: {:noreply, socket}
end

Demo.Tickets.start()
PhoenixPlayground.start(live: Demo.Live, port: String.to_integer(System.get_env("PORT", "4000")))
