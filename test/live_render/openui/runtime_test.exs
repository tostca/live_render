defmodule LiveRender.OpenUI.RuntimeTest do
  @moduledoc """
  Streaming (language.md, section 4), the state store (5.1) and error emission (8.3) as the
  runtime sees them.
  """

  use ExUnit.Case, async: true

  alias LiveRender.OpenUI.{Conformance, Runtime}
  alias LiveRender.OpenUI.RuntimeHarness, as: H

  @named """
  root = Stack([name])
  name = Input("n", "Name", $name)
  """

  describe "streaming and state defaults" do
    test "state defaults initialize as their statements arrive" do
      h = H.mount("", streaming: true)
      h = H.push(h, "$a = 1\n")
      assert H.state(h) == %{"$a" => 1}
      h = H.push(h, "$b = [1, 2]\nroot = Stack([Text(\"\" + $a)])\n")
      assert H.state(h) == %{"$a" => 1, "$b" => [1, 2]}
      assert Runtime.streaming?(h.rt)
    end

    test "a default read from a truncated statement is replaced by the full one" do
      h = H.mount("", streaming: true)
      h = H.push(h, @named <> ~s($name = "Al))
      assert H.state(h) == %{"$name" => "Al"}

      h = H.push(h, ~s(ice"\n))
      assert H.state(h) == %{"$name" => "Alice"}
      h = H.end_stream(h)
      assert H.state(h) == %{"$name" => "Alice"}
    end

    test "a value the user changed while streaming is kept" do
      h = H.mount("", streaming: true)
      h = H.push(h, @named <> ~s($name = "Al))
      h = H.input(h, "name", "Bob")
      h = h |> H.push(~s(ice"\n)) |> H.end_stream()
      assert H.state(h) == %{"$name" => "Bob"}
    end

    test "declared defaults are not a user change: no :state effect" do
      h = H.mount("", streaming: true)
      h = h |> H.push(@named <> ~s($name = "x"\n)) |> H.end_stream()
      assert h.states == []
    end

    test "a $name still growing at the end of the text is not declared" do
      h = H.mount("", streaming: true)
      h = H.push(h, ~s|root = Stack([Text($na|)
      refute Map.has_key?(H.state(h), "$na")
      h = h |> H.push(~s|me)])\n|) |> H.end_stream()
      assert H.state(h) == %{"$name" => nil}
    end

    test "an undeclared $name is declared with null" do
      h = H.mount(@named)
      assert H.state(h) == %{"$name" => nil}
    end

    test "parsing again never deletes a store key" do
      h = H.mount(@named <> ~s($name = "x"\n$gone = 3\n))
      h = H.run(h, Runtime.set_response(h.rt, ~s|root = Stack([Text("new")])|, true))
      assert H.state(h) == %{"$name" => "x", "$gone" => 3}
      h = H.end_stream(h)
      assert H.state(h) == %{"$name" => "x", "$gone" => 3}
    end

    test "a new parse does not overwrite a value the user produced" do
      h = H.mount(@named <> ~s($name = "x"\n))
      h = H.input(h, "name", "typed")
      h = H.run(h, Runtime.set_response(h.rt, @named <> ~s($name = "y"\n), false))
      assert H.state(h) == %{"$name" => "typed"}
    end

    test "a pristine default follows a new parse" do
      h = H.mount(@named <> ~s($name = "x"\n))
      h = H.run(h, Runtime.set_response(h.rt, @named <> ~s($name = "y"\n), false))
      assert H.state(h) == %{"$name" => "y"}
    end

    test "persisted initial state wins over declared defaults, and @Reset restores the default" do
      text = @named <> ~s($name = "default"\nreset = Button("R", @Reset($name\)\)\n)
      text = String.replace(text, "Stack([name])", "Stack([name, reset])")

      h =
        H.mount(text,
          initial_state: %{
            "$name" => "saved",
            "form" => %{"f" => %{value: 1, componentType: :input}}
          }
        )

      assert H.state(h)["$name"] == "saved"
      assert H.state(h)["form"] == %{"f" => %{"value" => 1, "componentType" => "input"}}

      h = H.run(h, Runtime.set_response(h.rt, text, false))
      assert H.state(h)["$name"] == "saved"

      h = H.click(h, "reset")
      assert H.state(h)["$name"] == "default"
    end

    test "persisted state also wins while streaming" do
      h = H.mount("", streaming: true, initial_state: %{"$name" => "saved"})
      h = H.push(h, @named <> ~s($name = "Al))
      assert H.state(h)["$name"] == "saved"
    end

    test "the tree renders after every chunk" do
      h = H.mount("", streaming: true)
      h = H.push(h, ~s|root = Stack([Text("he|)

      assert %{"type" => "Stack", "props" => %{"children" => [%{"props" => %{"text" => "he"}}]}} =
               H.summary(h)

      h = H.push(h, ~s|llo")])\n|)
      assert %{"props" => %{"children" => [%{"props" => %{"text" => "hello"}}]}} = H.summary(h)
    end

    test "end_stream finalizes a pending redefinition of an earlier name" do
      h = H.mount("", streaming: true)
      h = H.push(h, ~s|root = Stack([t])\nt = Text("one")\nt = Text("tw|)
      assert %{"props" => %{"children" => [%{"props" => %{"text" => "one"}}]}} = H.summary(h)
      h = H.end_stream(h)
      assert %{"props" => %{"children" => [%{"props" => %{"text" => "tw"}}]}} = H.summary(h)
    end

    test "start on a streaming runtime does nothing; start on an ended one runs queries" do
      lib = Conformance.library()
      text = ~s|root = Stack([Text("x")])\nq = Query("t", {}, null)\n|

      assert {_, []} = Runtime.start(Runtime.new(lib, response: text, streaming: true))
      assert {_, [{:call_tool, 1, "t", %{}}]} = Runtime.start(Runtime.new(lib, response: text))
    end

    test "after a new stream ends, a changed query fetches and an unchanged one does not" do
      text = ~s|root = Stack([Text("x")])\na = Query("a", {}, null)\nb = Query("b", {}, null)\n|
      h = H.mount(text, tools: %{"a" => 1, "b" => 2})
      h = H.reset(h)

      # The reference keeps its query cache across streams, so an unchanged query is not refetched.
      h =
        H.run(
          h,
          Runtime.set_response(h.rt, String.replace(text, ~s|"b", {}|, ~s|"b", {x: 1}|), true)
        )

      assert h.calls == []
      h = H.end_stream(h)
      assert [%{tool: "b", args: %{"x" => 1}}] = h.calls
    end

    test "a query removed by a new program stops; its late result is ignored" do
      text = ~s|root = Stack([Text("x")])\nq = Query("t", {}, {n: 1}, 5)\n|
      h = H.mount(text, tools: %{"t" => :hold})
      [ref] = H.pending_refs(h)
      [timer] = Map.keys(h.timers)

      h = H.run(h, Runtime.set_response(h.rt, ~s|root = Stack([Text("y")])|, false))
      h = H.reset(h) |> H.deliver(ref, {:ok, %{n: 2}})
      assert h.effects == []
      assert Runtime.query_status(h.rt)["__openui_loading"] == []
      assert H.fire(h, timer).calls == []
    end
  end

  describe "bindings under a ternary root (1.1)" do
    @ternary """
    $mode = "edit"
    $note = "first"
    root = $mode == "edit" ? Stack([note, done]) : Stack([Text($note)])
    note = Input("note", "Note", $note)
    done = Button("Done", @Set($mode, "view"))
    """

    # A runtime root gives elements without statement ids, so they are reached by path.
    defp at(h, path) do
      {:ok, el, _form} = LiveRender.OpenUI.Tree.at_path(Runtime.tree(h.rt), h.rt.lib, path)
      Conformance.summarize(el, Runtime.eval_ctx(h.rt))["props"]
    end

    test "an input bound inside a ternary root stays editable and keeps its value" do
      input = ["children", 0]
      binding = %{"$binding" => "$note"}
      h = H.mount(@ternary)
      assert at(h, input)["value"] == binding

      h = H.run(h, Runtime.input(h.rt, input, "second"))
      assert H.state(h)["$note"] == "second"
      assert at(h, input)["value"] == binding

      h = H.run(h, Runtime.input(h.rt, input, "third"))
      assert H.state(h)["$note"] == "third"

      h = H.run(h, Runtime.click(h.rt, ["children", 1]))
      assert H.state(h) == %{"$mode" => "view", "$note" => "third"}
      assert at(h, ["children", 0])["text"] == "third"
    end
  end

  describe "error emission" do
    @broken ~s|root = Stack([Foo("x")])\n|

    test "parser errors are not reported while streaming, and are emitted once at stream end" do
      h = H.mount("", streaming: true)
      h = H.push(h, @broken)
      assert h.errors == []
      assert Runtime.errors(h.rt) == []

      h = H.end_stream(h)
      assert [[%{code: "unknown-component", statement_id: "root"}]] = h.errors
    end

    test "an unchanged list is never emitted again" do
      h = H.mount(@broken <> ~s|$v = 1\n|)
      assert length(h.errors) == 1

      h = H.run(h, Runtime.set_response(h.rt, Runtime.text(h.rt), false))
      assert length(h.errors) == 1
    end

    test "a clean program emits nothing" do
      h = H.mount(~s|root = Stack([Text("ok")])|)
      assert h.errors == []
    end

    test "a new stream clears the errors and emits an empty list" do
      h = H.mount(@broken)
      h = H.reset(h)

      h = H.run(h, Runtime.set_response(h.rt, ~s|root = Stack([Te|, true))
      assert h.errors == [[]]

      h = H.push(h, ~s|xt("ok")])\n|) |> H.end_stream()
      assert h.errors == [[]]
    end

    test "a new stream with no earlier errors emits nothing" do
      h = H.mount(~s|root = Stack([Text("ok")])|)
      h = H.run(h, Runtime.set_response(h.rt, ~s|root = Stack([])|, true))
      assert h.errors == []
    end

    test "pushing after the stream ended starts a new stream" do
      h = H.mount(@broken)
      h = h |> H.reset() |> H.push("x = 1\n")
      assert h.errors == [[]]
      assert Runtime.streaming?(h.rt)

      h = H.end_stream(h)
      assert [[], [%{code: "unknown-component"}]] = h.errors
    end

    test "errors come back after the new stream ends when the program still has them" do
      h = H.mount(@broken)
      h = H.reset(h)
      h = H.run(h, Runtime.set_response(h.rt, @broken, true))
      h = H.end_stream(h)
      assert [[], [%{code: "unknown-component"}]] = h.errors
    end

    test "query errors are hidden while a new stream streams" do
      text = ~s|root = Stack([Text("x")])\nq = Query("t", {}, null)\n|
      h = H.mount(text, tools: %{})
      assert H.error_codes(h) == ["tool-not-found"]

      h = H.run(h, Runtime.set_response(h.rt, text <> "y = 1\n", true))
      assert Runtime.errors(h.rt) == []
      h = H.end_stream(h)
      assert H.error_codes(h) == ["tool-not-found"]
    end
  end

  describe "limits" do
    test "a response longer than max_bytes is cut there, still renders, and is reported" do
      text = ~s|root = Stack([Text("kept")])\nfiller = Text("#{String.duplicate("é", 400)}")\n|
      rt = Runtime.new(Conformance.library(), response: text, max_bytes: 60)
      {rt, effects} = Runtime.start(rt)

      assert %{props: %{"children" => [%{props: %{"text" => "kept"}}]}} = Runtime.tree(rt)
      assert [{:errors, [error | _]}] = for({:errors, _} = e <- effects, do: e)
      assert error.code == "runtime-error"
      assert error.message =~ "only the first 60 were read"
      assert String.valid?(Runtime.text(rt))
    end
  end
end
