defmodule LiveRender.OpenUI.ConversationTest do
  use ExUnit.Case, async: true

  alias LiveRender.OpenUI.{Conversation, StandardLibrary}

  test "the model never sees marker lines; user events carry their context and form values" do
    lib = StandardLibrary.library(version: "1.0.0")

    conv =
      Conversation.new()
      |> Conversation.add_user("Show open tickets")
      |> Conversation.add_assistant("root = Stack([Text(\"Hi\")])",
        library: lib,
        state: %{"$q" => "x"}
      )
      |> Conversation.add_event(%{
        "type" => "continue_conversation",
        "humanFriendlyMessage" => "Close it",
        "params" => %{"context" => %{"id" => 7}},
        "formState" => %{"$q" => "x"}
      })

    [user, assistant, event] = Conversation.for_model(conv)

    for m <- [user, assistant, event], do: refute(m.content =~ "]]>openui:")

    assert user == %{role: :user, content: "Show open tickets"}
    assert assistant.content == "root = Stack([Text(\"Hi\")])"
    assert event.content =~ "Close it\ncontext and form values = "
    assert event.content =~ ~s(["User clicked: Close it",{"$q":"x"},{"id":7}])

    [_, %{stored: stored}, _] = Conversation.messages(conv)
    assert stored =~ "]]>openui:content?library=live_render%401.0.0"
    assert stored =~ "]]>openui:end"
    assert Conversation.stored_state(stored) == %{"$q" => "x"}
    assert Conversation.display(stored) == "root = Stack([Text(\"Hi\")])"
  end

  test "current_program merges edit-mode patches in order" do
    conv =
      Conversation.new()
      |> Conversation.add_assistant("root = Stack([a])\na = Text(\"A\")")
      |> Conversation.add_assistant("a = Text(\"A2\")")

    assert Conversation.current_program(conv) == "a = Text(\"A2\")"
    assert Conversation.current_program(conv, true) == "root = Stack([a])\na = Text(\"A2\")"

    restored = conv |> Conversation.messages() |> Conversation.from_messages()

    assert Conversation.current_program(restored, true) ==
             Conversation.current_program(conv, true)
  end
end
