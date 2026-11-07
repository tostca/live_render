defmodule LiveRender.OpenUI.Live do
  @moduledoc """
  A LiveComponent that renders and runs one OpenUI program.

      <.live_component
        module={LiveRender.OpenUI.Live}
        id="answer-42"
        library={@library}
        response={@text}
        streaming={@streaming?}
        tools={MyApp.OpenUITools}
        tool_context={%{actor: @current_user, tenant: @org_id}}
      />

  Attributes:

    * `library` (required) — a `LiveRender.OpenUI.Library`
    * `response` — the program text received so far; may contain message markers
    * `streaming` — true while more text will arrive. Queries and mutations wait for the end.
    * `edit_base` — set in edit mode: the current program. `response` is then a patch, merged
      once it has finished streaming (language.md, section 7); until then `edit_base` renders.
    * `tools` — see `LiveRender.OpenUI.ToolHost`; only these tools can run
    * `tool_context` — passed to every tool call (actor, tenant, ...). Programs cannot read it.
    * `initial_state` — persisted state to restore (from an earlier `{:state, map}` message)
    * `notify` — pid that receives messages (default: the parent LiveView)
    * `tool_timeout` — milliseconds before a tool call fails (default 30_000)
    * `max_concurrency` — tool calls in flight at once (default 8)
    * `max_bytes` — the longest response read (default 512 KB); the rest is ignored and reported
    * `class` — CSS class of the wrapper

  The component sends `{:openui, id, message}` to the parent LiveView:

    * `{:event, event}` — a host event: `continue_conversation`, `open_url`, or a custom action
      (language.md, section 6.3). The host decides what to do; nothing is sent to the model by
      this component.
    * `{:errors, [LiveRender.OpenUI.Error.t()]}` — the error list, only when it changes
    * `{:state, map}` — the user or an action changed state; store it to restore later
    * `{:program, text}` — the merged program at the end of an edit-mode stream

  Tools run in `start_async/3` tasks, so a slow tool never blocks rendering. Refresh timers run
  the same way.
  """

  use Phoenix.LiveComponent

  alias LiveRender.OpenUI.{Editing, JS, Render, Runtime, ToolHost, Tree}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       runtime: nil,
       broken: MapSet.new(),
       last_good: %{},
       render_errors: [],
       emitted_errors: [],
       seen: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(
        Map.take(assigns, [:id, :library, :tools, :tool_context, :notify, :class, :tool_timeout])
      )
      |> assign_new(:tools, fn -> nil end)
      |> assign_new(:tool_context, fn -> %{} end)
      |> assign_new(:notify, fn -> nil end)
      |> assign_new(:class, fn -> nil end)
      |> assign_new(:tool_timeout, fn -> 30_000 end)

    response = Map.get(assigns, :response, "")
    streaming = Map.get(assigns, :streaming, false)
    edit_base = Map.get(assigns, :edit_base)
    seen = {response, streaming, edit_base}

    cond do
      socket.assigns.runtime == nil ->
        text =
          if edit_base && streaming,
            do: edit_base,
            else: program_text(response, streaming, edit_base)

        runtime =
          Runtime.new(socket.assigns.library,
            response: text,
            streaming: streaming and is_nil(edit_base),
            initial_state: Map.get(assigns, :initial_state, %{}),
            max_concurrency: Map.get(assigns, :max_concurrency, 8),
            max_bytes: Map.get(assigns, :max_bytes, 512_000)
          )

        {runtime, effects} = Runtime.start(runtime)

        {:ok,
         socket
         |> assign(runtime: runtime, seen: seen)
         |> run(effects)
         |> after_change()
         |> maybe_report_program(edit_base, streaming, text)}

      seen != socket.assigns.seen ->
        {:ok, socket |> assign(seen: seen) |> receive_text(response, streaming, edit_base)}

      true ->
        {:ok, socket}
    end
  end

  defp program_text(response, _streaming, nil), do: response
  defp program_text(response, false, base), do: Editing.merge(base, response)
  defp program_text(_response, true, base), do: base

  # In edit mode the base keeps rendering while the patch streams; it merges once at the end.
  defp receive_text(socket, _response, true, base) when is_binary(base), do: socket

  defp receive_text(socket, response, streaming, base) do
    text = program_text(response, streaming, base)
    {runtime, effects} = Runtime.set_response(socket.assigns.runtime, text, streaming)

    socket
    |> assign(runtime: runtime)
    |> run(effects)
    |> after_change()
    |> maybe_report_program(base, streaming, text)
  end

  defp maybe_report_program(socket, base, false, text) when is_binary(base),
    do: notify(socket, {:program, text})

  defp maybe_report_program(socket, _base, _streaming, _text), do: socket

  # ── Events ───────────────────────────────────────────────────────────────

  @impl true
  def handle_event("openui:click", %{"node" => node} = params, socket) do
    prop = Map.get(params, "prop", "action")

    with {:ok, path} <- Tree.decode_path(node),
         true <- is_binary(prop) and Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]{0,63}\z/, prop) do
      # Skipping validation only lets a non-submitting button run; it never adds authority.
      opts = [validate: Map.get(params, "validate") != "false"]
      {runtime, effects} = Runtime.click(socket.assigns.runtime, path, prop, opts)
      {:noreply, socket |> assign(runtime: runtime) |> run(effects) |> after_change()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("openui:input", %{"node" => node} = params, socket) do
    case Tree.decode_path(node) do
      {:ok, path} ->
        value = params |> Map.get("value") |> coerce(Map.get(params, "type"))
        {runtime, effects} = Runtime.input(socket.assigns.runtime, path, value)
        {:noreply, socket |> assign(runtime: runtime) |> run(effects) |> after_change()}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("openui:submit", _params, socket), do: {:noreply, socket}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A field may say how to read its raw form value; the value itself still comes from the user.
  # `list` takes `value[]` inputs (a hidden blank one keeps an empty choice from vanishing);
  # `joined` joins them with commas, as a date range ("from,to").
  defp coerce(v, "boolean"), do: v in ["true", "on", true]
  defp coerce(v, "list"), do: v |> List.wrap() |> Enum.filter(&(is_binary(&1) and &1 != ""))
  defp coerce(v, "joined"), do: v |> coerce("list") |> Enum.join(",")

  defp coerce(v, "number") when is_binary(v) do
    if JS.trim(v) == "", do: nil, else: JS.to_number(v)
  end

  defp coerce(v, _type) when is_binary(v) or is_nil(v) or is_list(v), do: v
  defp coerce(_v, _type), do: nil

  @impl true
  def handle_async({:openui_tool, ref}, result, socket) do
    result =
      case result do
        {:ok, {:ok, _} = ok} -> ok
        {:ok, {:error, _} = error} -> error
        {:ok, other} -> {:error, inspect(other)}
        {:exit, reason} -> {:error, "tool call exited: #{inspect(reason)}"}
      end

    {runtime, effects} = Runtime.tool_result(socket.assigns.runtime, ref, result)
    {:noreply, socket |> assign(runtime: runtime) |> run(effects) |> after_change()}
  end

  def handle_async({:openui_timer, ref}, {:ok, :tick}, socket) do
    {runtime, effects} = Runtime.timer(socket.assigns.runtime, ref)
    {:noreply, socket |> assign(runtime: runtime) |> run(effects) |> after_change()}
  end

  def handle_async(_name, _result, socket), do: {:noreply, socket}

  # ── Effects ──────────────────────────────────────────────────────────────

  defp run(socket, effects) do
    Enum.reduce(effects, socket, fn
      {:call_tool, ref, name, args}, s ->
        %{tools: tools, tool_context: context, tool_timeout: timeout} = s.assigns

        start_async(s, {:openui_tool, ref}, fn ->
          call_with_timeout(tools, name, args, context, timeout)
        end)

      {:schedule, ref, ms}, s ->
        start_async(s, {:openui_timer, ref}, fn ->
          Process.sleep(ms)
          :tick
        end)

      {:event, event}, s ->
        notify(s, {:event, event})

      {:state, state}, s ->
        notify(s, {:state, state})

      # The component emits one combined list (runtime and render errors) in after_change/1.
      {:errors, _}, s ->
        s
    end)
  end

  defp call_with_timeout(tools, name, args, context, timeout) do
    task = Task.async(fn -> ToolHost.call(tools, name, args, context) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "tool call exited: #{inspect(reason)}"}
      nil -> {:error, "tool call timed out after #{timeout} ms"}
    end
  end

  defp notify(socket, message) do
    send(socket.assigns.notify || self(), {:openui, socket.assigns.id, message})
    socket
  end

  # Finds renderers that raise (outside the render phase), remembers good nodes, and emits the
  # error list when it changed.
  defp after_change(socket) do
    runtime = socket.assigns.runtime
    tree = Runtime.tree(runtime)
    {broken, render_errors} = Render.check(tree, ctx(socket))

    last_good =
      tree
      |> Tree.elements(socket.assigns.library)
      |> Enum.reduce(socket.assigns.last_good, fn {el, path, _form}, acc ->
        if MapSet.member?(broken, path), do: acc, else: Map.put(acc, path, el)
      end)

    errors =
      if Runtime.streaming?(runtime), do: [], else: Runtime.errors(runtime) ++ render_errors

    socket = assign(socket, broken: broken, last_good: last_good, render_errors: render_errors)

    if errors == socket.assigns.emitted_errors,
      do: socket,
      else: socket |> assign(emitted_errors: errors) |> notify({:errors, errors})
  end

  defp ctx(socket) do
    %Render.Ctx{
      lib: socket.assigns.library,
      runtime: socket.assigns.runtime,
      target: socket.assigns.myself,
      dom_id: socket.assigns.id,
      streaming: Runtime.streaming?(socket.assigns.runtime),
      broken: socket.assigns.broken,
      last_good: socket.assigns.last_good
    }
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :ctx, ctx(assigns_socket(assigns)))

    ~H"""
    <div id={@id} class={@class} data-openui-root data-streaming={to_string(@ctx.streaming)}>
      <Render.tree tree={Runtime.tree(@runtime)} openui={@ctx} />
    </div>
    """
  end

  # `ctx/1` reads socket assigns; in render we only have assigns.
  defp assigns_socket(assigns), do: %{assigns: assigns}
end
