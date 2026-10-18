defmodule LiveRender.OpenUI.TestEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :live_render

  socket("/live", Phoenix.LiveView.Socket)
end

defmodule LiveRender.OpenUI.TestHostLive do
  @moduledoc """
  A host LiveView for integration tests. Session keys:

    * `"program"`, `"streaming"`, `"edit_base"` — passed to the component
    * `"library"` — `"standard"` or `"fixtures"`
    * `"tools"` — pid of an Agent holding `%{results: %{name => result}, calls: [...]}`, or nil
    * `"test_pid"` — receives `{:openui_msg, message}` for every component message

  Send `{:set_program, text, streaming}` to the view process to stream more text.
  """
  use Phoenix.LiveView

  alias LiveRender.OpenUI.{Conformance, Live, StandardLibrary}

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       program: session["program"] || "",
       streaming: session["streaming"] || false,
       edit_base: session["edit_base"],
       library: library(session["library"]),
       tools: tools(session["tools"]),
       test_pid: session["test_pid"]
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={Live}
      id="ui"
      library={@library}
      response={@program}
      streaming={@streaming}
      edit_base={@edit_base}
      tools={@tools}
      tool_context={%{actor: "tester"}}
    />
    """
  end

  @impl true
  def handle_info({:openui, "ui", message}, socket) do
    if socket.assigns.test_pid, do: send(socket.assigns.test_pid, {:openui_msg, message})
    {:noreply, socket}
  end

  def handle_info({:set_program, text, streaming}, socket) do
    {:noreply, assign(socket, program: text, streaming: streaming)}
  end

  defp library("fixtures"), do: LiveRender.OpenUI.LiveFixtures.library()

  defp library("boom") do
    boom =
      LiveRender.OpenUI.Library.component("Boom",
        props: [explode: %{"type" => "boolean"}],
        renderer: &LiveRender.OpenUI.LiveFixtures.boom/1
      )

    StandardLibrary.library(extra: [boom])
  end

  defp library(_), do: StandardLibrary.library()

  # Tools read their results from an Agent so a test can change them between interactions.
  defp tools(nil), do: nil

  defp tools(agent) when is_pid(agent) do
    names = Agent.get(agent, &Map.keys(&1.results))

    Map.new(names, fn name ->
      {name,
       fn args ->
         Agent.get_and_update(agent, fn s ->
           {{:ok, s.results[name]}, %{s | calls: s.calls ++ [%{"tool" => name, "args" => args}]}}
         end)
       end}
    end)
  end

  # Keep the alias used so the compiler does not warn when only one library is referenced.
  @doc false
  def fixture_library, do: Conformance.library()
end

defmodule LiveRender.OpenUI.LiveFixtures do
  @moduledoc """
  The conformance fixture library with test renderers for `Form`, `Input` and `Button` (README,
  "Action and form cases"). Each rendered node carries `data-statement` so tests can find it.
  """
  use Phoenix.Component

  alias LiveRender.OpenUI.{Conformance, Library, Render}

  def library do
    lib = Conformance.library()

    renderers = %{
      "Form" => &form_node/1,
      "Input" => &input/1,
      "Button" => &button/1,
      "Text" => &text/1
    }

    components =
      Map.new(lib.components, fn {name, c} ->
        {name, %{c | renderer: Map.get(renderers, name)}}
      end)

    %Library{lib | components: components}
  end

  def form_node(assigns) do
    ~H"""
    <div data-statement={@openui.element.statement_id} data-form={@props["name"]}>
      <Render.children openui={@openui} prop="children" />
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div data-statement={@openui.element.statement_id}>
      <Render.field_form openui={@openui}>
        <input name="value" value={Render.text(Render.field_value(@openui))} />
      </Render.field_form>
    </div>
    """
  end

  def button(assigns) do
    ~H"""
    <button data-statement={@openui.element.statement_id} {Render.click_attrs(@openui, "action")}>
      {Render.text(@props["label"])}
    </button>
    """
  end

  def text(assigns) do
    ~H"""
    <p data-statement={@openui.element.statement_id}>{Render.text(@props["text"])}</p>
    """
  end

  # A host renderer that raises on some input, as a buggy custom component would.
  def boom(assigns) do
    if assigns.props["explode"] == true, do: raise(ArgumentError, "boom")

    ~H"""
    <p>calm</p>
    """
  end
end
