defmodule LiveRender.OpenUI.Conversation do
  @moduledoc """
  A chat history stored the way prompt.md, sections 6 and 7 describe: every message is text with
  `]]>openui:` marker lines, and the model only ever sees the content.

      conv =
        Conversation.new()
        |> Conversation.add_user("Show open tickets")
        |> Conversation.add_assistant(response_text, library: library, state: form_state)

      # A button sent {:openui, id, {:event, %{"type" => "continue_conversation"} = event}}
      conv = Conversation.add_event(conv, event)

      Conversation.for_model(conv)
      #=> [%{role: :user, content: "Show open tickets"}, %{role: :assistant, content: "root = ..."}, ...]

  Store `messages/1` (plain strings) wherever the application keeps chat history; `from_messages/1`
  restores it.
  """

  alias LiveRender.OpenUI.{Editing, Library, Protocol}

  defstruct messages: []

  @type role :: :user | :assistant
  @type message :: %{role: role(), stored: String.t()}
  @type t :: %__MODULE__{messages: [message()]}

  @doc "An empty conversation."
  def new, do: %__MODULE__{}

  @doc "Restores a conversation from `[%{role, stored}]` maps."
  def from_messages(messages) do
    %__MODULE__{
      messages:
        Enum.map(
          messages,
          &%{role: to_role(&1[:role] || &1["role"]), stored: &1[:stored] || &1["stored"]}
        )
    }
  end

  defp to_role(r) when r in [:user, "user"], do: :user
  defp to_role(r) when r in [:assistant, "assistant"], do: :assistant

  @doc "The stored messages, oldest first."
  def messages(%__MODULE__{messages: m}), do: m

  @doc "Adds a user message typed by a person."
  def add_user(%__MODULE__{} = conv, text), do: push(conv, :user, Protocol.build(content: text))

  @doc """
  Adds the user turn produced by a `continue_conversation` event: the message, and a context
  section with `["User clicked: <message>", formState, context?]` (prompt.md, section 6.3).
  """
  def add_event(%__MODULE__{} = conv, %{"humanFriendlyMessage" => message} = event) do
    context = get_in(event, ["params", "context"])
    context = if is_nil(context), do: :none, else: context
    push(conv, :user, Protocol.user_turn(message, event["formState"], context))
  end

  @doc """
  Adds a finished assistant response. Options:

    * `:library` — writes `library=<id>@<version>` on the content marker
    * `:state` — the program's state (form values) to store with it, restored on re-render
    * `:ended` — whether the stream reached its end (default true)
  """
  def add_assistant(%__MODULE__{} = conv, text, opts \\ []) do
    attributes =
      case opts[:library] do
        %Library{} = lib -> Protocol.library_attributes(lib)
        _ -> %{}
      end

    context = if opts[:state], do: [opts[:state]]

    stored =
      Protocol.build(
        content: text,
        attributes: attributes,
        context: context,
        end: Keyword.get(opts, :ended, true)
      )

    push(conv, :assistant, stored)
  end

  defp push(conv, role, stored),
    do: %{conv | messages: conv.messages ++ [%{role: role, stored: stored}]}

  @doc """
  The messages as the model sees them: assistant turns as their program text only, user turns as
  the message plus `context and form values = <JSON>`. No marker line reaches the model.
  """
  @spec for_model(t()) :: [%{role: role(), content: String.t()}]
  def for_model(%__MODULE__{messages: messages}) do
    Enum.map(messages, fn
      %{role: :assistant, stored: s} -> %{role: :assistant, content: Protocol.for_model(s)}
      %{role: :user, stored: s} -> %{role: :user, content: Protocol.user_turn_for_model(s)}
    end)
  end

  @doc "The text of an assistant message for display: its content, without markers or context."
  def display(stored), do: Protocol.parse(stored).content

  @doc """
  The persisted state stored with an assistant message (`add_assistant/3`'s `:state`), or `%{}`.
  Pass it as `initial_state` when rendering the message again.
  """
  def stored_state(stored) do
    case Protocol.parse(stored).context do
      [state | _] when is_map(state) -> state
      _ -> %{}
    end
  end

  @doc """
  The current program: the content of the last assistant message, with every edit-mode patch
  after it merged in order when `patches?` is true.
  """
  def current_program(%__MODULE__{messages: messages}, patches? \\ false) do
    programs = for %{role: :assistant, stored: s} <- messages, do: Protocol.parse(s).content

    case programs do
      [] ->
        nil

      [first | rest] ->
        if patches?,
          do: Enum.reduce(rest, first, &Editing.merge(&2, &1)),
          else: List.last(programs)
    end
  end
end
