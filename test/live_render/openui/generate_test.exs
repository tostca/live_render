defmodule LiveRender.OpenUI.GenerateTest do
  use ExUnit.Case, async: true

  alias LiveRender.OpenUI.{Conversation, Generate, StandardLibrary}

  defp text_of(message), do: message.content |> Enum.map_join(& &1.text)

  test "the request carries the generated prompt, clean history, tool descriptors and the current program" do
    conv =
      Conversation.new()
      |> Conversation.add_user("Make a dashboard")
      |> Conversation.add_assistant("root = Stack([Text(\"Hi\")])", end: true)

    [system, user1, assistant, request] =
      Generate.messages("Rename the title",
        library: StandardLibrary.library(),
        conversation: conv,
        tools: %{"listTickets" => fn _ -> {:ok, []} end},
        edit: "root = Stack([Text(\"Hi\")])"
      )

    assert system.role == :system
    assert text_of(system) =~ "listTickets"
    assert text_of(system) =~ "## Edit Mode"
    assert text_of(user1) == "Make a dashboard"
    assert text_of(assistant) == "root = Stack([Text(\"Hi\")])"

    assert text_of(request) =~
             "Current program:\n```openui-lang\nroot = Stack([Text(\"Hi\")])\n```\n\nRename the title"

    for m <- [system, user1, assistant, request], do: refute(text_of(m) =~ "]]>openui:")
  end
end
