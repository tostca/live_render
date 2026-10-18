defmodule LiveRender.OpenUI.ProtocolTest do
  @moduledoc "The message protocol (prompt.md, section 7)."

  use ExUnit.Case, async: true

  import LiveRender.OpenUI.TestHelpers, only: [summary: 1]

  alias LiveRender.OpenUI.{Protocol, Source}
  alias LiveRender.OpenUI.Protocol.Message

  @m "]]>openui:"

  describe "reading" do
    test "the example message" do
      text = """
      #{@m}content?library=support%401.2.0
      root = Card([title, saveBtn])
      title = TextContent("Order")
      #{@m}context
      {"formState":{"note":"rush"},"context":{"orderId":42}}
      #{@m}end
      """

      assert %Message{
               content: "root = Card([title, saveBtn])\ntitle = TextContent(\"Order\")",
               context: %{"formState" => %{"note" => "rush"}, "context" => %{"orderId" => 42}},
               attributes: %{"library" => "support@1.2.0"},
               end: true
             } = Protocol.parse(text)
    end

    test "the last content section wins" do
      text = "#{@m}content\nold = 1\n#{@m}end\n#{@m}content\nnew = 2"
      assert %Message{content: "new = 2", end: false} = Protocol.parse(text)
    end

    test "a context or end before the winning content belongs to an earlier attempt" do
      text = "#{@m}content\nold\n#{@m}context\n{\"a\":1}\n#{@m}end\n#{@m}content\nnew"
      assert %Message{content: "new", context: nil, end: false} = Protocol.parse(text)
    end

    test "text before the first marker is the content only without a content marker" do
      assert Protocol.parse("a = 1\nb = 2").content == "a = 1\nb = 2"
      assert Protocol.parse("a = 1\n#{@m}context\n{}").content == "a = 1"
      assert Protocol.parse("a = 1\n#{@m}context\n{}").context == %{}
      assert Protocol.parse("prose\n#{@m}content\nb = 2").content == "b = 2"
    end

    test "unknown kinds are stripped with their text" do
      text = "#{@m}content\na = 1\n#{@m}thinking?x=1\nsecret\nmore\n#{@m}context\n[1]"
      assert %Message{content: "a = 1", context: [1]} = Protocol.parse(text)
    end

    test "unknown attributes are kept as data and do not matter" do
      assert Protocol.parse("#{@m}content?foo=bar&library=x\na").attributes ==
               %{"foo" => "bar", "library" => "x"}
    end

    test "attributes decode like URLSearchParams" do
      attrs =
        Protocol.parse("#{@m}content?library=a%40b&name=two+words&raw=x@y&empty=&flag\nc").attributes

      assert attrs == %{
               "library" => "a@b",
               "name" => "two words",
               "raw" => "x@y",
               "empty" => "",
               "flag" => ""
             }
    end

    test "older libraryVersion attributes are returned like any other" do
      assert Protocol.parse("#{@m}content?libraryVersion=1.0\nc").attributes == %{
               "libraryVersion" => "1.0"
             }
    end

    test "a malformed percent escape does not crash" do
      assert Protocol.parse("#{@m}content?a=%ZZ&b=%E2%82\nc").content == "c"
    end

    test "the newline before a marker is not part of the body; CRLF is accepted" do
      text = "#{@m}content\r\na = 1\r\n#{@m}context\r\n{\"k\":1}\r\n#{@m}end\r\n"
      assert %Message{content: "a = 1", context: %{"k" => 1}, end: true} = Protocol.parse(text)
    end

    test "a marker counts only at the start of a line" do
      text = "#{@m}content\na = \"x #{@m}context y\"\nb = 1"
      assert Protocol.parse(text).content == "a = \"x #{@m}context y\"\nb = 1"
    end

    test "a mid-line content marker starts a new line, so the regenerated content wins" do
      text =
        "#{@m}content\nroot = Stack([Text(\"cut of#{@m}content\nroot = Stack([Text(\"new\")])"

      assert Protocol.parse(text).content == "root = Stack([Text(\"new\")])"

      at_end = "#{@m}content\nfirst = 1#{@m}content"
      assert Protocol.parse(at_end).content == ""

      with_attrs = "#{@m}content\ncut#{@m}content?library=x%401\nnew = 1"

      assert %Message{content: "new = 1", attributes: %{"library" => "x@1"}} =
               Protocol.parse(with_attrs)
    end

    test "other mid-line markers are ordinary text" do
      text = "#{@m}content\na = 1 #{@m}end\nb = 2"
      assert Protocol.parse(text).content == "a = 1 #{@m}end\nb = 2"
      # `]]>openui:contents` is not a content marker.
      assert Protocol.parse("#{@m}content\nx#{@m}contents\ny").content == "x#{@m}contents\ny"
    end

    test "text after end stays with the section the end line interrupted" do
      text = "#{@m}content\na = 1\n#{@m}end\nb = 2"
      assert %Message{content: content, end: true} = Protocol.parse(text)
      assert content =~ "a = 1"
      assert content =~ "b = 2"
    end

    test "a missing end means the stream died, but the content still renders" do
      assert %Message{content: "a = 1", end: false} = Protocol.parse("#{@m}content\na = 1")
    end

    test "a context that is not JSON is returned as text" do
      assert Protocol.parse("#{@m}content\na\n#{@m}context\nnot json").context == "not json"
    end

    test "the parser renders only the content" do
      text =
        "#{@m}content?library=fixtures%401.0.0\nroot = Stack([Text(\"m\")])\n#{@m}context\n{\"a\":1}\n#{@m}end"

      assert summary(text).root == %{
               "type" => "Stack",
               "props" => %{"children" => [%{"type" => "Text", "props" => %{"text" => "m"}}]}
             }
    end
  end

  describe "streaming hold-back" do
    test "a last line that is a prefix of a marker is held back until its newline arrives" do
      for partial <- [
            "]",
            "]]",
            "]]>",
            "]]>open",
            "]]>openui:",
            "]]>openui:cont",
            "]]>openui:end"
          ] do
        text = "#{@m}content\na = 1\n" <> partial
        assert Protocol.parse(text, streaming: true).content == "a = 1", partial
      end
    end

    test "held-back text is released when it is not a marker after all" do
      assert Protocol.parse("#{@m}content\na = 1\n]x", streaming: true).content == "a = 1\n]x"
      assert Protocol.parse("a = 1\n]]x", streaming: true).content == "a = 1\n]]x"
    end

    test "without streaming nothing is held back" do
      assert Protocol.parse("#{@m}content\na = 1\n]]>open").content == "a = 1\n]]>open"
    end

    test "a partial content marker at the end of a line is held back" do
      for partial <- ["]]>", "]]>openui:", "]]>openui:con", "]]>openui:content"] do
        text = "#{@m}content\nroot = 1 cut" <> partial
        assert Protocol.parse(text, streaming: true).content == "root = 1 cut", partial
      end
    end

    test "a partial marker with no marker before it is held back in source preparation" do
      assert Source.prepare("a = 1\n]]>openu", streaming: true) == "a = 1"
      assert Source.prepare("a = 1\n]]>openu") == "a = 1\n]]>openu"

      # At the end of a complete message, `]]>openui:co` is a marker line of the unknown kind `co`.
      assert Source.prepare("a = 1\n]]>openui:co") == "a = 1"
    end
  end

  describe "writing" do
    test "build/1 writes content, context, attributes and end" do
      text =
        Protocol.build(
          content: "root = Card([])",
          context: %{"formState" => %{"note" => "rush"}},
          attributes: %{"library" => "support@1.2.0"},
          end: true
        )

      assert text ==
               "#{@m}content?library=support%401.2.0\nroot = Card([])\n#{@m}context\n" <>
                 ~s({"formState":{"note":"rush"}}) <> "\n#{@m}end"
    end

    test "attributes encode like URLSearchParams" do
      text = Protocol.build(content: "", attributes: [{"name", "a b&c=d/é~*-._"}])
      assert text == "#{@m}content?name=a+b%26c%3Dd%2F%C3%A9%7E*-._\n"
    end

    test "build/1 and parse/2 round-trip" do
      cases = [
        [content: "a = 1"],
        [content: "a = 1\nb = \"x\"", end: true],
        [
          content: "a = 1",
          context: [%{"x" => 1}, "y"],
          attributes: %{"library" => "lib@1.0 beta"}
        ],
        [content: "", context: "raw text"],
        [content: "line\n\nwith blank lines\n", end: true]
      ]

      for input <- cases do
        msg = Protocol.parse(Protocol.build(input))
        assert msg.content == Keyword.fetch!(input, :content), inspect(input)
        assert msg.context == Keyword.get(input, :context), inspect(input)
        assert msg.end == Keyword.get(input, :end, false), inspect(input)

        assert msg.attributes == Map.new(Keyword.get(input, :attributes, %{})), inspect(input)
      end
    end

    test "library_attributes/1" do
      assert Protocol.library_attributes(%{id: "support", version: "1.2.0"}) == %{
               "library" => "support@1.2.0"
             }

      assert Protocol.library_attributes(%{id: "support", version: nil}) == %{
               "library" => "support"
             }

      assert Protocol.library_attributes(%{id: nil, version: "1"}) == %{}
    end

    test "user_turn/3 writes the reference format" do
      assert Protocol.user_turn("Save", %{"note" => "rush"}) ==
               "#{@m}content\nSave\n#{@m}context\n" <> ~s(["User clicked: Save",{"note":"rush"}])

      assert Protocol.user_turn("Save", nil, %{"id" => 1}) ==
               "#{@m}content\nSave\n#{@m}context\n" <> ~s(["User clicked: Save",{},{"id":1}])

      assert Protocol.user_turn("Pick", %{}, 0) =~ ~s(["User clicked: Pick",{},0])
    end

    test "what the model sees has no markers" do
      stored = Protocol.build(content: "a = 1", context: %{"x" => 1}, end: true)
      assert Protocol.for_model(stored) == "a = 1"

      turn = Protocol.user_turn("Save", %{"note" => "rush"})

      assert Protocol.user_turn_for_model(turn) ==
               "Save\ncontext and form values = " <> ~s(["User clicked: Save",{"note":"rush"}])
    end
  end
end
