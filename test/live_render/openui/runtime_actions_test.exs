defmodule LiveRender.OpenUI.RuntimeActionsTest do
  @moduledoc "Mutations (language.md, section 6.2), action plans and host events (6.3)."

  use ExUnit.Case, async: true

  alias LiveRender.OpenUI.{Conformance, Runtime}
  alias LiveRender.OpenUI.RuntimeHarness, as: H

  @create """
  $title = "Bug"
  root = Stack([title, create, status])
  title = Input("title", "Title", $title)
  newTicket = Mutation("createTicket", {title: $title})
  create = Button("Create", Action([@Run(newTicket), @ToAssistant("Created")]))
  status = Text(newTicket.status)
  """

  defp status(h), do: H.props(h, "status")["text"]

  describe "click props" do
    test "only the action prop has a default event; naming another prop does nothing" do
      h = H.mount(~s|root = Stack([go])\ngo = Button("Go")|)
      assert H.click(h, "go", "label").events == []
      assert [%{"humanFriendlyMessage" => "Go"}] = H.click(h, "go").events
    end
  end

  describe "form validation scope" do
    @form """
    $n = 0
    root = Stack([Form("f", [Input("email", "Email", null, {required: true}), bump, send])])
    bump = Button("Bump", @Set($n, $n + 1))
    send = Button("Send", @ToAssistant("Send"))
    """

    test "a plan that only sets state does not submit, so it is not blocked" do
      h = H.mount(@form) |> H.click("bump")
      assert Runtime.state(h.rt)["$n"] == 1
    end

    test "a submitting plan is blocked until fields pass, unless validation is skipped" do
      h = H.mount(@form)
      assert H.click(h, "send").events == []

      assert [%{"humanFriendlyMessage" => "Send"}] =
               H.click(h, "send", "action", validate: false).events
    end
  end

  describe "mutations" do
    test "never run on load" do
      h = H.mount(@create, tools: %{"createTicket" => %{"id" => 7}})
      assert h.calls == []
      assert status(h) == "idle"

      assert Runtime.mutation(h.rt, "newTicket") == %{
               "status" => "idle",
               "data" => nil,
               "error" => nil
             }
    end

    test "status goes idle, loading, success; the plan continues after the result" do
      h = H.mount(@create, tools: %{"createTicket" => :hold})
      h = H.click(h, "create")

      assert [%{tool: "createTicket", args: %{"title" => "Bug"}}] = h.calls
      assert status(h) == "loading"
      assert h.events == []

      [ref] = H.pending_refs(h)
      h = H.deliver(h, ref, {:ok, %{id: 7}})
      assert status(h) == "success"
      assert Runtime.mutation(h.rt, "newTicket")["data"] == %{"id" => 7}

      assert [%{"type" => "continue_conversation", "humanFriendlyMessage" => "Created"}] =
               h.events
    end

    test "args are evaluated with the state at run time" do
      h = H.mount(@create, tools: %{"createTicket" => %{}})
      h = h |> H.input("title", "Crash") |> H.click("create")
      assert [%{args: %{"title" => "Crash"}}] = h.calls

      h =
        H.mount(
          """
          $title = "a"
          root = Stack([go])
          m = Mutation("save", {title: $title})
          go = Button("Go", Action([@Set($title, "b"), @Run(m)]))
          """,
          tools: %{"save" => %{}}
        )

      h = H.click(h, "go")
      assert [%{args: %{"title" => "b"}}] = h.calls
    end

    test "a second run while loading is rejected and stops that plan" do
      h = H.mount(@create, tools: %{"createTicket" => :hold})
      h = h |> H.click("create") |> H.click("create")
      assert length(h.calls) == 1
      assert h.events == []

      [ref] = H.pending_refs(h)
      h = H.deliver(h, ref, {:ok, %{}})
      assert length(h.events) == 1

      # Once settled it runs again.
      h = H.click(h, "create")
      assert length(h.calls) == 2
    end

    test "a failed mutation sets status error and stops the remaining actions" do
      h = H.mount(@create, tools: %{"createTicket" => {:error, "duplicate"}})
      h = H.click(h, "create")

      assert status(h) == "error"
      assert h.events == []

      assert %{"status" => "error", "data" => nil, "error" => msg} =
               Runtime.mutation(h.rt, "newTicket")

      assert msg == "Mutation \"createTicket\" failed: duplicate"
      assert [[%{source: :mutation, code: "tool-error", statement_id: "newTicket"}]] = h.errors
    end

    test "a missing tool fails the mutation with tool-not-found and a hint" do
      h = H.mount(@create, tools: %{"other" => []})
      h = H.click(h, "create")

      assert h.events == []

      assert [
               [
                 %{
                   code: "tool-not-found",
                   hint: "Available tools: other",
                   tool_name: "createTicket"
                 }
               ]
             ] =
               h.errors
    end

    test "a later success clears the mutation error" do
      h = H.mount(@create, tools: %{"createTicket" => {:error, "x"}})
      h = h |> H.click("create") |> H.put_tool("createTicket", %{}) |> H.click("create")
      assert List.last(h.errors) == []
      assert status(h) == "success"
    end

    # The reference drops a @Run whose target is not a query or mutation; the rest still runs.
    test "@Run of an unknown statement is dropped" do
      h =
        H.mount("""
        root = Stack([go])
        go = Button("Go", Action([@Run(missing), @ToAssistant("after")]))
        """)

      h = H.click(h, "go")
      assert h.calls == []
      assert [%{"humanFriendlyMessage" => "after"}] = h.events
    end

    test "a query @Run reached while a new stream streams waits for the stream end" do
      text = """
      root = Stack([go])
      m = Mutation("save", {})
      q = Query("list", {}, [])
      go = Button("Go", Action([@Run(m), @Run(q)]))
      """

      h = H.mount(text, tools: %{"save" => :hold, "list" => []})
      h = H.click(h, "go")
      [ref] = H.pending_refs(h)

      h = H.run(h, Runtime.set_response(h.rt, text, true)) |> H.reset()
      h = H.deliver(h, ref, {:ok, nil})
      assert h.calls == []

      h = H.end_stream(h)
      assert H.call_names(h) == ["list"]
    end

    test "a mutation success can trigger a query refetch later in the plan" do
      h =
        H.mount(
          """
          root = Stack([go])
          m = Mutation("save", {})
          q = Query("list", {}, [])
          go = Button("Go", Action([@Run(m), @Run(q), @ToAssistant("done")]))
          """,
          tools: %{"save" => :hold, "list" => []}
        )

      h = H.click(h, "go")
      assert H.call_names(h) == ["list", "save"]
      [ref] = H.pending_refs(h)
      h = H.deliver(h, ref, {:ok, nil})
      assert H.call_names(h) == ["list", "save", "list"]
      assert [%{"humanFriendlyMessage" => "done"}] = h.events
    end
  end

  describe "action order and state" do
    test "@Set, @Reset and events run in order, each event seeing the state at its step" do
      h =
        H.mount("""
        $n = 1
        $m = 7
        root = Stack([go])
        go = Button("Go", Action([@Set($n, $n + 1), @ToAssistant("one"), @Set($m, 9), @OpenUrl("https://x.test"), @Reset($n, $m), @CopyToClipboard("hi"), @ToAssistant("two")]))
        """)

      h = H.click(h, "go")

      assert [
               %{"type" => "continue_conversation", "formState" => %{"$n" => 2, "$m" => 7}},
               %{
                 "type" => "open_url",
                 "params" => %{"url" => "https://x.test"},
                 "humanFriendlyMessage" => "",
                 "formState" => %{"$n" => 2, "$m" => 9}
               },
               %{
                 "type" => "CopyToClipboard",
                 "params" => %{"text" => "hi"},
                 "humanFriendlyMessage" => "",
                 "formState" => %{"$n" => 1, "$m" => 7}
               },
               %{"humanFriendlyMessage" => "two"}
             ] = h.events

      assert H.state(h) == %{"$n" => 1, "$m" => 7}
    end

    test "@Set evaluates its value when the action runs" do
      h =
        H.mount("""
        $count = 0
        root = Stack([inc, Text("" + $count)])
        inc = Button("Inc", @Set($count, $count + 1))
        """)

      h = h |> H.click("inc") |> H.click("inc") |> H.click("inc")
      assert H.state(h)["$count"] == 3
      assert Enum.map(h.states, & &1["$count"]) == [1, 2, 3]
    end

    test "@Reset restores the declared default, or null, and the key is pristine again" do
      h =
        H.mount(
          """
          $a = "x"
          root = Stack([setb, reset])
          setb = Button("SetB", Action([@Set($a, "user"), @Set($b, 5)]))
          reset = Button("Reset", @Reset($a, $b))
          """,
          streaming: true
        )

      h = H.end_stream(h)
      h = h |> H.click("setb") |> H.click("reset")
      assert H.state(h) == %{"$a" => "x", "$b" => nil}
      assert MapSet.member?(h.rt.store.pristine, "$a")

      # A pristine key takes a new default from the next program.
      h =
        H.run(
          h,
          Runtime.set_response(h.rt, String.replace(Runtime.text(h.rt), ~s("x"), ~s("y")), false)
        )

      assert H.state(h)["$a"] == "y"
    end

    test "a plain list of actions is data: no plan runs" do
      h =
        H.mount("""
        $saved = false
        root = Stack([save])
        save = Button("Save", [@Set($saved, true), @ToAssistant("Saved")])
        """)

      h = H.click(h, "save")
      assert H.state(h)["$saved"] == false
      refute Enum.any?(h.events, &(&1["humanFriendlyMessage"] == "Saved"))
      # The reference button treats a non-plan action like a legacy object: label message.
      assert [%{"type" => "continue_conversation", "humanFriendlyMessage" => "Save"}] = h.events
    end

    test "a button with no action sends continue_conversation with its label" do
      h = H.mount(~s|root = Stack([b])\nb = Button("Hello there")|)
      h = H.click(h, "b")

      assert [
               %{
                 "type" => "continue_conversation",
                 "humanFriendlyMessage" => "Hello there",
                 "params" => %{}
               } = event
             ] = h.events

      refute Map.has_key?(event, "formName")
    end

    test "a missing secondary action prop does nothing; a present one runs" do
      h =
        H.mount("""
        root = Stack([a, b])
        a = Button("A")
        b = Button("B", null, null, @CopyToClipboard("link"))
        """)

      assert H.click(h, "a", "share").events == []

      assert [%{"type" => "CopyToClipboard", "params" => %{"text" => "link"}}] =
               H.click(h, "b", "share").events
    end

    test "a custom action with an invalid argument does nothing; the rest of the plan runs" do
      h =
        H.mount("""
        $n = "a"
        $m = null
        root = Stack([a, b, c, inp])
        inp = Input("x", "X", $n)
        a = Button("A", @CopyToClipboard($n))
        b = Button("B", @CopyToClipboard($m))
        c = Button("C", Action([@CopyToClipboard($n), @ToAssistant("after")]))
        """)

      assert h.errors == []

      assert [%{"type" => "CopyToClipboard", "params" => %{"text" => "a"}}] =
               H.click(h, "a").events

      # A required argument that is null when the action is built: nothing, with no error.
      assert H.click(h, "b").events == []

      # One known only at runtime reports runtime-error, emitted with the next render.
      h = H.input(h, "inp", 5)
      assert [[%{code: "runtime-error", statement_id: "a"}, %{code: "runtime-error"}]] = h.errors
      assert H.click(h, "a").events == []
      assert [%{"humanFriendlyMessage" => "after"}] = H.click(h, "c").events

      h = H.input(h, "inp", "ok")
      assert List.last(h.errors) == []
    end

    test "@ToAssistant context reaches params.context unchanged" do
      h =
        H.mount("""
        $id = "T-42"
        root = Stack([b])
        b = Button("Close", @ToAssistant("Ticket closed", {ticket: $id, n: [1, null]}))
        """)

      assert [%{"params" => %{"context" => %{"ticket" => "T-42", "n" => [1, nil]}}}] =
               H.click(h, "b").events
    end

    test "a legacy action object still sends its event, but cannot pose as a custom action" do
      h =
        H.mount("""
        root = Stack([a, b])
        a = Button("Open", {type: "open_url", url: "https://x.test"})
        b = Button("Copy", {type: "CopyToClipboard", params: {text: "x"}})
        """)

      assert [%{"type" => "open_url", "params" => %{"url" => "https://x.test"}}] =
               H.click(h, "a").events

      assert H.click(h, "b").events == []
    end

    test "no interaction runs while streaming" do
      h = H.mount("", streaming: true, tools: %{"save" => %{}})

      h =
        H.push(h, """
        $n = 1
        root = Stack([go])
        m = Mutation("save", {})
        go = Button("Go", Action([@Set($n, 2), @Run(m), @ToAssistant("x")]))
        """)

      assert {_rt, []} = Runtime.click(h.rt, H.path(h, "go"))
      assert {_rt, []} = Runtime.click_statement(h.rt, "go")

      h = h |> H.end_stream() |> H.click("go")
      assert H.state(h)["$n"] == 2
      assert length(h.events) == 1
    end
  end

  describe "event shape and form state" do
    @form """
    $q = "find"
    root = Stack([Form("ticket", [status, send]), page, outside])
    status = Input("status", "Status")
    send = Button("Send", @ToAssistant("Ticket closed"))
    page = Input("note", "Note")
    outside = Button("Outside", @ToAssistant("Out"))
    """

    test "inside a form: formName and only that form's fields" do
      h = H.mount(@form)
      h = h |> H.input("status", "closed") |> H.input("page", "hi") |> H.click("send")

      assert [
               %{
                 "type" => "continue_conversation",
                 "humanFriendlyMessage" => "Ticket closed",
                 "params" => %{},
                 "formName" => "ticket",
                 "formState" => %{
                   "ticket" => %{"status" => %{"value" => "closed", "componentType" => "input"}}
                 }
               } = event
             ] = h.events

      assert map_size(event["formState"]) == 1
    end

    test "inside a form with no fields yet: the form name with no fields" do
      h = H.mount(@form)

      assert [%{"formName" => "ticket", "formState" => %{"ticket" => %{}}}] =
               H.click(h, "send").events
    end

    test "a button with no action inside a form sends its label with the form state" do
      h =
        H.mount("""
        root = Stack([Form("f", [a, submit])])
        a = Input("a", "A", null, {required: true})
        submit = Button("Submit")
        """)

      assert H.click(h, "submit").events == []

      h = h |> H.input("a", "x") |> H.click("submit")

      assert [
               %{
                 "type" => "continue_conversation",
                 "humanFriendlyMessage" => "Submit",
                 "formName" => "f",
                 "formState" => %{"f" => %{"a" => %{"value" => "x"}}}
               }
             ] = h.events
    end

    test "outside a form: $variables plain, page-level fields wrapped, no formName" do
      h = H.mount(@form)
      h = h |> H.input("page", "hi") |> H.click("outside")

      assert [event] = h.events
      refute Map.has_key?(event, "formName")

      assert event["formState"] == %{
               "$q" => "find",
               "note" => %{"value" => "hi", "componentType" => "input"}
             }
    end

    test "form fields keep their values across a new parse" do
      h = H.mount(@form)
      h = H.input(h, "status", "closed")
      h = H.run(h, Runtime.set_response(h.rt, @form <> "extra = 1\n", false))

      assert H.state(h)["ticket"] == %{
               "status" => %{"value" => "closed", "componentType" => "input"}
             }

      field = H.props(h, "status")
      assert field["name"] == "status"
    end

    test "nested forms: the nearest form names the scope" do
      h =
        H.mount("""
        root = Stack([Form("outer", [a, Form("inner", [b, send])])])
        a = Input("a", "A")
        b = Input("b", "B")
        send = Button("Send", @ToAssistant("x"))
        """)

      h = h |> H.input("a", "1") |> H.input("b", "2") |> H.click("send")

      assert H.state(h) == %{
               "outer" => %{"a" => %{"value" => "1", "componentType" => "input"}},
               "inner" => %{"b" => %{"value" => "2", "componentType" => "input"}}
             }

      assert [%{"formName" => "inner", "formState" => %{"inner" => _} = fs}] = h.events
      assert map_size(fs) == 1
    end
  end

  describe "bindings and inputs" do
    test "a binding writes the $variable, not the form" do
      h =
        H.mount("""
        $email = ""
        root = Stack([Form("f", [email]), Text($email)])
        email = Input("email", "Email", $email)
        """)

      h = H.input(h, "email", "a@b.co")
      assert H.state(h) == %{"$email" => "a@b.co"}
      assert [%{"$email" => "a@b.co"}] = h.states
      assert Runtime.field_value(h.rt, find(h, "email"), "f") == "a@b.co"
    end

    test "an unbound field shows its stored value, else its static value" do
      h =
        H.mount("""
        root = Stack([Form("f", [a])])
        a = Input("a", "A")
        """)

      assert Runtime.field_value(h.rt, find(h, "a"), "f") == nil
      h = H.input(h, "a", "typed")
      assert Runtime.field_value(h.rt, find(h, "a"), "f") == "typed"
    end

    test "input into something that holds no value changes nothing" do
      h =
        H.mount("""
        root = Stack([Form("f", [b])])
        b = Button("B")
        """)

      form_path = ["children", 0]
      assert {_, []} = Runtime.input(h.rt, form_path, "x")
      assert {_, []} = Runtime.input(h.rt, H.path(h, "b"), "x")
      assert H.state(h) == %{}
    end

    test "a field without a library componentType writes its type name" do
      h =
        H.mount("""
        root = Stack([s])
        s = Select("size", [SelectItem("s", "Small"), SelectItem("l", "Large")])
        """)

      h = H.input(h, "s", "l")
      assert H.state(h) == %{"size" => %{"value" => "l", "componentType" => "select"}}
    end

    test "input values are normalized" do
      h =
        H.mount("""
        $n = 0
        root = Stack([a])
        a = Input("a", "A", $n)
        """)

      h = H.input(h, "a", 2.0)
      assert H.state(h)["$n"] === 2
    end

    defp find(h, id) do
      {:ok, el, _path, _form} =
        LiveRender.OpenUI.Tree.find_statement(Runtime.tree(h.rt), h.rt.lib, id)

      el
    end
  end

  describe "validation in forms" do
    @signup """
    root = Stack([Form("signup", [email, age, send]), out])
    email = Input("email", "Email", null, {required: true, email: true})
    age = Input("age", "Age", null, {numeric: true, min: 18})
    send = Button("Send", Action([@Set($sent, true), @ToAssistant("Sign up")]))
    out = Button("Out", @ToAssistant("out"))
    """

    test "a failing field blocks the plan and records field errors" do
      h = H.mount(@signup)
      h = H.click(h, "send")

      assert h.events == []
      assert H.state(h)["$sent"] == nil
      assert Runtime.field_error(h.rt, "signup", "email") == "This field is required"
      assert Runtime.field_error(h.rt, "signup", "age") == nil
    end

    test "the error follows the value and clears once it passes" do
      h = H.mount(@signup)
      h = h |> H.click("send") |> H.input("email", "nope")
      assert Runtime.field_error(h.rt, "signup", "email") == "Please enter a valid email"

      h = H.input(h, "email", "a@b.co")
      assert Runtime.field_error(h.rt, "signup", "email") == nil
    end

    test "a field with no error is not validated while typing" do
      h = H.mount(@signup)
      h = H.input(h, "age", "3")
      assert Runtime.field_error(h.rt, "signup", "age") == nil

      h = H.click(h, "send")
      assert Runtime.field_error(h.rt, "signup", "age") == "Must be at least 18"
    end

    test "once every field passes, the plan runs" do
      h = H.mount(@signup)
      h = h |> H.input("email", "a@b.co") |> H.input("age", "21") |> H.click("send")

      assert [%{"formName" => "signup", "humanFriendlyMessage" => "Sign up"}] = h.events
      assert H.state(h)["$sent"] == true
    end

    test "clicks outside the form are never blocked" do
      h = H.mount(@signup)
      assert [%{"humanFriendlyMessage" => "out"}] = H.click(h, "out").events
    end

    test "bound fields validate their $variable" do
      h =
        H.mount("""
        $code = "ab"
        root = Stack([Form("f", [code, send])])
        code = Input("code", "Code", $code, {pattern: "^[A-Z]{2}\\\\d{3}$"})
        send = Button("Send", @ToAssistant("go"))
        """)

      h = H.click(h, "send")
      assert h.events == []
      assert Runtime.field_error(h.rt, "f", "code") == "Invalid format"

      h = h |> H.input("code", "AB123") |> H.click("send")
      assert Runtime.field_error(h.rt, "f", "code") == nil
      assert [%{"humanFriendlyMessage" => "go"}] = h.events
    end
  end

  describe "paths" do
    test "click and input address elements by tree path" do
      h =
        H.mount("""
        $v = ""
        root = Stack([Card("c", [a, b])])
        a = Input("a", "A", $v)
        b = Button("B", @Set($v, "clicked"))
        """)

      lib = h.rt.lib

      paths =
        for {el, path, _} <- LiveRender.OpenUI.Tree.elements(Runtime.tree(h.rt), lib),
            into: %{},
            do: {el.statement_id || el.type_name, path}

      assert paths["a"] == ["children", 0, "children", 0]
      h = H.run(h, Runtime.input(h.rt, paths["a"], "typed"))
      assert H.state(h)["$v"] == "typed"
      h = H.run(h, Runtime.click(h.rt, paths["b"]))
      assert H.state(h)["$v"] == "clicked"
    end

    test "a bad path is a no-op" do
      h = H.mount(~s|root = Stack([b])\nb = Button("B")|)

      for path <- [
            ["nope"],
            ["children", 5],
            ["children", -1],
            ["children", "x"],
            [0],
            ["children", 0, "label", 0]
          ] do
        assert {rt, []} = Runtime.click(h.rt, path)
        assert rt == h.rt
        assert {^rt, []} = Runtime.input(h.rt, path, "x")
      end
    end

    test "clicking a component that is not a button sends its label like the reference button" do
      h = H.mount(~s|root = Stack([t])\nt = Text("hello")|)
      # Text has no label prop: the message is empty.
      assert [%{"humanFriendlyMessage" => ""}] = H.click(h, "t").events
    end

    test "with no tree, interactions do nothing" do
      rt = Runtime.new(Conformance.library(), response: "")
      assert {^rt, []} = Runtime.click(rt, [])
      assert {^rt, []} = Runtime.input(rt, [], "x")
    end
  end
end
