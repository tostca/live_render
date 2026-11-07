defmodule LiveRender.OpenUI.EvaluationTest do
  @moduledoc "Evaluation (language.md, sections 2 and 3): built-ins, member access, @Each, functions."

  use ExUnit.Case, async: true

  import LiveRender.OpenUI.TestHelpers

  alias LiveRender.OpenUI.{ActionPlan, Evaluator, Library}

  @rows ~s([{id: 1, name: "b", n: "10", c: {city: "Oslo"}}, {id: 2, name: "a", n: "9", c: {city: "Bergen"}}, {id: 3, name: "C", n: 2, c: null}])

  defp rows_ev(expr), do: ev(expr, "rows = " <> @rows)

  describe "@Count @First @Last" do
    test "arrays and non-arrays" do
      assert ev("@Count([1, 2, 3])") == 3
      assert ev("@Count([])") == 0
      assert ev(~s'@Count("abc")') == 0
      assert ev("@Count(null)") == 0
      assert ev("@First([4, 5])") == 4
      assert ev("@Last([4, 5])") == 5
      assert ev("@First([])") == nil
      assert ev("@Last([])") == nil
      assert ev(~s'@First("abc")') == nil
      assert ev("@Last({a: 1})") == nil
    end

    test "an unresolved reference as a direct array element is left out" do
      assert ev("@Count([a, b])", "a = 1") == 1
      assert ev("@Count([a, b, null])", "a = 1") == 2
      assert ev("[a, b]", "a = 1") == [1]
    end

    test "an unresolved reference outside an array literal is null" do
      assert ev("@Count(missing)") == 0
      assert ev("[missing.x]") == [nil]
    end
  end

  describe "@Sum @Avg @Min @Max" do
    test "with toNumber" do
      assert ev(~s'@Sum([1, "2", true, null, "x"])') == 4
      assert ev(~s'@Avg([1, "2", 3])') == 2
      assert ev("@Avg([1, 2])") == 1.5
      assert ev(~s'@Min([3, "1", 2])') == 1
      assert ev(~s'@Max([3, "10", 2])') == 10
      assert ev("@Min([-1, null])") == -1
      assert ev("@Max([-1, null])") == 0
    end

    test "empty arrays and non-arrays" do
      for f <- ~w(Sum Avg Min Max) do
        assert ev("@#{f}([])") == 0, f
        assert ev("@#{f}(5)") == 0, f
        assert ev("@#{f}(null)") == 0, f
      end
    end

    test "floating point sums follow doubles" do
      assert ev("@Sum([0.1, 0.2])") == 0.30000000000000004
    end
  end

  describe "@Filter" do
    test "every operator" do
      assert rows_ev(~s|@Filter(rows, "id", "==", "2").name|) == ["a"]
      assert rows_ev(~s|@Filter(rows, "id", "!=", 2).name|) == ["b", "C"]
      assert rows_ev(~s|@Filter(rows, "n", ">", 5).name|) == ["b", "a"]
      assert rows_ev(~s|@Filter(rows, "n", "<", "9").name|) == ["C"]
      assert rows_ev(~s|@Filter(rows, "n", ">=", 9).name|) == ["b", "a"]
      assert rows_ev(~s|@Filter(rows, "n", "<=", 9).name|) == ["a", "C"]
    end

    test "contains is a case-sensitive substring of the field as a string" do
      assert rows_ev(~s|@Filter(rows, "name", "contains", "c").name|) == []
      assert rows_ev(~s|@Filter(rows, "name", "contains", "C").name|) == ["C"]
      assert rows_ev(~s|@Filter(rows, "id", "contains", 1).name|) == ["b"]
      assert ev(~s|@Filter(["apple", "Apricot", null], "", "contains", "ap")|) == ["apple"]
      # A null field reads as "", which contains "".
      assert ev(~s|@Filter([null, "x"], "", "contains", "")|) == [nil, "x"]
    end

    test "an unknown op matches nothing; a missing op means ==" do
      assert rows_ev(~s|@Filter(rows, "id", "~", 1)|) == []
      assert rows_ev(~s|@Filter(rows, "id", null, 1).name|) == ["b"]
      assert rows_ev(~s|@Filter(rows, "id").name|) == []
    end

    test "an empty field tests the elements themselves" do
      assert ev(~s|@Filter([1, 5, "7", 10], "", ">", 4)|) == [5, "7", 10]
      assert ev(~s|@Filter([1, "1", true], "", "==", 1)|) == [1, "1", true]
    end

    test "dot paths" do
      assert rows_ev(~s|@Filter(rows, "c.city", "==", "Oslo").id|) == [1]
      assert rows_ev(~s|@Filter(rows, "c.city", "==", null).id|) == [3]
    end

    test "non-arrays give []" do
      assert ev(~s|@Filter("abc", "", "==", "abc")|) == []
      assert ev(~s|@Filter(null, "x", "==", 1)|) == []
    end
  end

  describe "@Sort" do
    test "numbers and numeric strings compare as numbers" do
      assert ev(~s|@Sort([10, "9", 1, "100"], "")|) == [1, "9", 10, "100"]
      assert rows_ev(~s|@Sort(rows, "n").name|) == ["C", "a", "b"]
    end

    test "other values compare with locale collation, null as empty" do
      assert ev(~s|@Sort(["b", "B", "a", "Z", "é"], "")|) == ["a", "b", "B", "é", "Z"]
      assert ev(~s|@Sort(["b", null, "a"], "")|) == [nil, "a", "b"]
      # A number and a non-numeric string compare as strings.
      assert ev(~s|@Sort(["b", 10, "a"], "")|) == [10, "a", "b"]
    end

    test "descending only with \"desc\"" do
      assert ev(~s|@Sort([2, 3, 1], "", "desc")|) == [3, 2, 1]
      assert ev(~s|@Sort([2, 3, 1], "", "DESC")|) == [1, 2, 3]
      assert ev(~s|@Sort([2, 3, 1], "", "asc")|) == [1, 2, 3]
    end

    test "dot paths" do
      assert rows_ev(~s|@Sort(rows, "c.city").id|) == [3, 2, 1]
    end

    test "the sort is stable, ascending and descending" do
      items = ~s|[{k: 1, i: "a"}, {k: 0, i: "b"}, {k: 1, i: "c"}, {k: 0, i: "d"}, {k: 1, i: "e"}]|
      assert ev(~s|@Sort(#{items}, "k").i|) == ["b", "d", "a", "c", "e"]
      assert ev(~s|@Sort(#{items}, "k", "desc").i|) == ["a", "c", "e", "b", "d"]
    end

    test "a non-array is returned unchanged" do
      assert ev(~s|@Sort("cba", "")|) == "cba"
      assert ev(~s|@Sort({a: 1}, "a")|) == %{"a" => 1}
    end

    test "a blank string is numeric (Number(\" \") is 0) but an empty one is not" do
      assert ev(~s|@Sort([1, " ", -1], "")|) == [-1, " ", 1]
    end
  end

  describe "@Round @Abs @Floor @Ceil" do
    test "@Round rounds halves up, as Math.round" do
      assert ev("@Round(2.5)") == 3
      assert ev("@Round(-2.5)") == -2
      assert ev("@Round(-2.6)") == -3
      assert ev("@Round(0.49999999999999994)") == 0
      assert ev(~s|"" + @Round(-0.4)|) == "0"
      assert ev(~s|@Round("3.7")|) == 4
      assert ev("@Round(null)") == 0
    end

    test "@Round with decimals" do
      assert ev("@Round(3.14159, 2)") == 3.14
      assert ev("@Round(1.005, 2)") == 1
      assert ev("@Round(-1.25, 1)") == -1.2
      assert ev("@Round(1234, -2)") == 1200
      assert ev("@Round(2.5, null)") == 3
    end

    test "@Abs @Floor @Ceil use toNumber" do
      assert ev(~s|@Abs("-3")|) == 3
      assert ev("@Abs(-0)") == 0
      assert ev("@Floor(-1.5)") == -2
      assert ev(~s|@Ceil("1.2")|) == 2
      assert ev("@Ceil(-1.5)") == -1
      assert ev(~s|@Floor("x")|) == 0
      assert ev(~s|@Abs("-Infinity")|) == :infinity
    end

    test "given a list, they apply to each element and keep the shape (1.1)" do
      assert ev("@Round([1.25, 2.5, null], 1)") == [1.3, 2.5, 0]
      assert ev(~s|@Abs([-1, "-2", [-3, [-4]]])|) == [1, 2, [3, [4]]]
      assert ev("@Floor([1.5, -1.5])") == [1, -2]
      assert ev("@Ceil([])") == []
      assert ev(~s|@Round([{a: 1}.a, "x"])|) == [1, 0]
    end

    test "@Round formats a plucked column" do
      rows = ~s|[{amount: 1.234}, {amount: 5.678}]|
      assert ev("@Round(#{rows}.amount, 2)") == [1.23, 5.68]
    end
  end

  describe "member access, pluck and indexing" do
    test "fields, pluck, length and null" do
      assert ev("{a: {b: 1}}.a.b") == 1
      assert ev("[{a: 1}, {b: 2}, null].a") == [1, nil, nil]
      assert ev("[[1, 2], [3]].length") == 2
      assert ev("[[1, 2], [3]].0") == [1, 3]
      assert ev("null.a") == nil
      assert ev("$unset.a.b") == nil
      assert ev("{length: 7}.length") == 7
      assert ev("[1, 2, 3].length + 1") == 4
    end

    test "m.0.1 reads the field \"0.1\"; index arrays with brackets" do
      assert ev(~s|{"0.1": "x", "0": {"1": "y"}}.0.1|) == "x"
      assert ev("[[1, 2], [3, 4]][1][0]") == 3
      assert ev(~s|[10, 20][1.0]|) == 20
      assert ev(~s|[10, 20]["1"]|) == 20
      assert ev("[10, 20][-1]") == nil
      assert ev("[10, 20][5]") == nil
      assert ev("[10, 20][0.5]") == nil
    end

    test "objects are indexed by string key; null object or index is null" do
      assert ev(~s|{a: 1, "1": 2}["a"]|) == 1
      assert ev("{a: 1, \"1\": 2}[1]") == 2
      assert ev("null[0]") == nil
      assert ev("[1][null]") == nil
    end

    test "a component instance reads as null through member access" do
      assert ev(~s|Text("x").text|) == nil
      assert ev(~s|[Text("x")].text|) == [nil]
    end
  end

  describe "@Each" do
    test "evaluates the template once per element" do
      assert ev(~s|@Each([1, 2, 3], "x", x * 10)|) == [10, 20, 30]
      assert ev(~s|@Each([{n: "a"}, {n: "b"}], "r", r.n + "!")|) == ["a!", "b!"]
      assert ev(~s|@Each([1, 2], x, x + 1)|) == [2, 3]
    end

    test "a non-array gives []" do
      assert ev(~s|@Each("ab", "x", x)|) == []
      assert ev(~s|@Each(null, "x", x)|) == []
      assert ev(~s|@Each([1], "x")|) == []
    end

    test "the loop variable shadows a statement of the same name" do
      {value, errors, _} = eval_stmt(~s|v = @Each([1, 2], "t", t + 1)\nt = 100|)
      assert value == [2, 3]
      assert errors == []
    end

    test "the loop variable exists only inside the template" do
      assert ev(~s|[@Each([1], "q", q), q]|) == [[1]]
    end

    test "a nested @Each with the same name shadows the outer one" do
      assert ev(~s|@Each([[1, 2], [3]], "x", @Each(x, "x", x * 2))|) == [[2, 4], [6]]
      assert ev(~s|@Each([1, 2], "x", @Each([10, 20], "y", x + y))|) == [[11, 21], [12, 22]]
    end

    test "actions inside the template capture their own element" do
      program =
        ~s|v = @Each(rows, "t", Button(t.title, @Set($sel, t.id)))\nrows = [{id: 1, title: "A"}, {id: 2, title: "B"}]|

      {[a, b], [], []} = eval_stmt(program)
      assert a.props["label"] == "A"
      assert b.props["label"] == "B"
      assert %ActionPlan{steps: [{:set, "$sel", ast_a}]} = a.props["action"]
      assert %ActionPlan{steps: [{:set, "$sel", ast_b}]} = b.props["action"]
      ctx = Evaluator.ctx(lib(), fn _ -> nil end, fn _ -> nil end)
      assert Evaluator.eval(ast_a, ctx) == 1
      assert Evaluator.eval(ast_b, ctx) == 2
    end

    test "Action([...]) in the template captures the element too" do
      program =
        ~s|v = @Each([{id: "x"}, {id: "y"}], "t", Action([@ToAssistant(t.id), @Set($s, t.id + "!")]))|

      {[a, b], [], []} = eval_stmt(program)
      assert [{:continue_conversation, "x", :none}, {:set, "$s", _}] = a.steps
      assert [{:continue_conversation, "y", :none}, {:set, "$s", set_b}] = b.steps
      ctx = Evaluator.ctx(lib(), fn _ -> nil end, fn _ -> nil end)
      assert Evaluator.eval(set_b, ctx) == "y!"
    end

    test "a huge @Each is cut and reported" do
      {value, _, runtime} =
        eval_stmt(
          ~s|v = @Each(big, "x", x)\nbig = #{inspect(Enum.to_list(1..10_050), limit: :infinity)}|
        )

      assert length(value) == 10_000
      assert codes(runtime) == ["runtime-error"]
    end
  end

  describe "Query and Mutation positions" do
    test "inline in a value position reports inline-reserved and renders nothing" do
      s = summary(~s|root = Stack([Text("a"), Query("t", {}, {})])|)
      assert s.root["props"]["children"] == [%{"type" => "Text", "props" => %{"text" => "a"}}]
      assert s.errors == [%{"code" => "inline-reserved", "statementId" => "root"}]

      s = summary(~s|root = Stack([Text("a"), Mutation("t", {})])|)
      assert s.errors == [%{"code" => "inline-reserved", "statementId" => "root"}]
    end

    test "in a computed expression it is null with no error" do
      {value, errors, runtime} = eval_stmt(~s|v = Query("t", {}, {rows: [1]}) == null|)
      assert value == true
      assert errors == []
      assert runtime == []
      assert ev(~s|{q: Query("t", {}, {})}|) == %{"q" => nil}
    end

    test "references to query statements resolve to their results" do
      assert ev("@Count(q.rows)", ~s|q = Query("t", {}, {rows: []})|,
               refs: %{"q" => %{"rows" => [1, 2]}}
             ) == 2
    end
  end

  describe "unknown functions" do
    test "evaluate to null and report unknown-function in nested expressions" do
      {value, errors, _} = eval_stmt(~s|v = [1 + @Nope(2), {a: @Nope()}.a, @Count([@Nope()])]|)
      assert value == [1, nil, 1]
      assert codes(errors) == ["unknown-function", "unknown-function", "unknown-function"]
      assert Enum.all?(errors, &(&1.statement_id == "v"))
    end

    test "the statement is kept" do
      s = summary(~s|root = Stack([t])\nt = Text("x" + @Nope())|)
      assert s.root["props"]["children"] == [%{"type" => "Text", "props" => %{"text" => "x"}}]
      assert s.errors == [%{"code" => "unknown-function", "statementId" => "t"}]
    end
  end

  describe "references" do
    test "a statement referenced twice is evaluated at each place" do
      assert ev("[a, a]", "a = {x: 1}") == [%{"x" => 1}, %{"x" => 1}]
    end

    test "a reference that closes a cycle is unresolved" do
      r = parse("root = Stack([Text(a)])\na = b + \"!\"\nb = a")
      assert "a" in r.unresolved
    end

    test "references are hoisted" do
      assert ev("later + 1", "later = 41") == 42
    end
  end

  # ── Custom functions and actions ─────────────────────────────────────────

  defp custom_lib do
    Library.new(
      id: "custom",
      root: "Stack",
      components: [
        Library.component("Stack", props: [children: Library.children()], required: [:children]),
        Library.component("Text", props: [text: %{"type" => "string"}], required: [:text]),
        Library.component("Button",
          props: [label: %{"type" => "string"}, action: Library.action_prop()],
          required: [:label]
        )
      ],
      functions: [
        Library.function("Percent",
          params: [
            part: %{"type" => "number"},
            total: %{"type" => "number"},
            digits: %{"type" => "number", "default" => 0}
          ],
          required: [:part, :total],
          returns: %{"type" => "string"},
          impl: fn %{"part" => p, "total" => t, "digits" => d} ->
            Float.round(p * 100 / t, d) |> to_string() |> Kernel.<>("%")
          end
        ),
        Library.function("Raises",
          params: [x: %{"type" => "number"}],
          impl: fn _ -> raise "boom" end
        ),
        Library.function("Throws", params: [], impl: fn _ -> throw(:oops) end),
        Library.function("Exits", params: [], impl: fn _ -> exit(:bye) end),
        Library.function("Wrong",
          params: [],
          returns: %{"type" => "string"},
          impl: fn _ -> 5 end
        ),
        Library.function("Echo",
          params: [a: %{"type" => "string"}, b: %{"type" => "string"}],
          required: [:a],
          impl: fn args -> args end
        ),
        Library.function("Tuple", params: [], impl: fn _ -> {:ok, self()} end)
      ],
      actions: [
        Library.action("Export",
          params: [
            name: %{"type" => "string"},
            format: %{"type" => "string", "enum" => ["csv", "xlsx"], "default" => "csv"}
          ],
          required: [:name]
        )
      ]
    )
  end

  defp cev(program), do: eval_stmt(program, "v", lib: custom_lib())

  describe "custom functions" do
    test "a valid call runs; missing optional args take their defaults" do
      assert {"50.0%", [], []} = cev("v = @Percent(1, 2)")
      assert {"33.3%", [], []} = cev("v = @Percent(1, 3, 1)")
      assert {"33.3%", [], []} = cev("v = @Percent(part, 3, 1)\npart = 1")
    end

    test "an explicit null for an optional argument takes its default" do
      assert {"50.0%", [], []} = cev("v = @Percent(1, 2, null)")
    end

    test "a function that raises reports runtime-error and evaluates to null" do
      {value, [], runtime} = cev("v = @Raises(1)")
      assert value == nil
      assert codes(runtime) == ["runtime-error"]
      assert hd(runtime).message =~ "boom"
    end

    test "a function that throws or exits reports runtime-error and evaluates to null" do
      for name <- ["Throws", "Exits"] do
        {value, [], runtime} = cev("v = @#{name}()")
        assert value == nil, name
        assert codes(runtime) == ["runtime-error"], name
      end
    end

    test "a return value that does not match returns reports runtime-error" do
      {value, [], runtime} = cev("v = @Wrong()")
      assert value == nil
      assert codes(runtime) == ["runtime-error"]
    end

    test "a return value that is not plain data is normalized" do
      {value, [], []} = cev("v = @Tuple()")
      assert [ok, pid] = value
      assert ok == "ok" and is_binary(pid)
    end

    test "a runtime-known invalid required argument reports runtime-error and gives null" do
      {value, [], runtime} = cev(~s|v = @Percent(part, 2)\npart = "x" + ""|)
      assert value == nil
      assert codes(runtime) == ["runtime-error"]
    end

    test "a runtime-known invalid optional argument is left out and reported" do
      {value, [], runtime} = cev(~s|v = @Echo("a", b)\nb = 1 + 1|)
      assert value == %{"a" => "a"}
      assert codes(runtime) == ["runtime-error"]
    end

    test "a null required argument at runtime gives null with no error" do
      assert {nil, [], []} = cev("v = @Percent($unset, 2)")
      assert {nil, [], []} = cev("v = @Percent(missing, 2)")
    end

    test "literal arguments are checked when parsing" do
      {value, errors, runtime} = cev(~s|v = @Percent("1", 2)|)
      assert value == nil
      assert codes(errors) == ["type-mismatch"]
      assert runtime == []

      {_, errors, _} = cev("v = @Percent(1)")
      assert codes(errors) == ["missing-required"]

      {_, errors, _} = cev("v = @Percent(null, 2)")
      assert codes(errors) == ["null-required"]

      {value, errors, _} = cev("v = @Percent(1, 2, 0, 9)")
      assert value == "50.0%"
      assert codes(errors) == ["excess-args"]
    end

    test "an invalid literal optional argument takes its default" do
      {value, errors, _} = cev(~s|v = @Percent(1, 2, "x")|)
      assert value == "50.0%"
      assert codes(errors) == ["type-mismatch"]
    end

    test "an invalid literal optional argument without a default is left out" do
      {value, errors, _} = cev(~s|v = @Echo("a", 5)|)
      assert value == %{"a" => "a"}
      assert codes(errors) == ["type-mismatch"]
    end
  end

  describe "custom actions" do
    test "a valid call is a one-step plan with params by name" do
      {plan, [], []} = cev(~s|v = @Export("r")|)

      assert %ActionPlan{steps: [{:custom, "Export", %{"name" => "r", "format" => "csv"}, _}]} =
               plan
    end

    test "any invalid literal argument, even an optional one with a default, gives an empty plan" do
      {plan, errors, _} = cev(~s|v = @Export("r", "pdf")|)
      assert plan == %ActionPlan{steps: []}
      assert codes(errors) == ["type-mismatch"]
    end

    test "an invalid runtime argument gives an empty plan and runtime-error" do
      {plan, [], runtime} = cev(~s|v = @Export("r", fmt)\nfmt = "p" + "df"|)
      assert plan == %ActionPlan{steps: []}
      assert codes(runtime) == ["runtime-error"]
    end

    test "a null required argument at runtime gives an empty plan with no error" do
      assert {%ActionPlan{steps: []}, [], []} = cev("v = @Export($unset)")
    end

    test "extra arguments are only dropped" do
      {plan, errors, _} = cev(~s|v = @Export("r", "xlsx", 1)|)
      assert %ActionPlan{steps: [{:custom, "Export", %{"format" => "xlsx"}, _}]} = plan
      assert codes(errors) == ["excess-args"]
    end
  end

  describe "built-in actions" do
    test "@ToAssistant context may be any value; null means none" do
      {plan, [], []} = eval_stmt(~s|v = @ToAssistant("hi", [1, {a: 2}])|)
      assert plan.steps == [{:continue_conversation, "hi", [1, %{"a" => 2}]}]
      {plan, [], []} = eval_stmt(~s|v = @ToAssistant("hi", null)|)
      assert plan.steps == [{:continue_conversation, "hi", :none}]
      {plan, [], []} = eval_stmt(~s|v = @ToAssistant("hi", 0)|)
      assert plan.steps == [{:continue_conversation, "hi", 0}]
    end

    test "@Run needs a query or mutation reference" do
      {plan, _, _} = eval_stmt(~s|v = @Run(q)\nq = Query("t", {}, {})|)
      assert plan.steps == [{:run, "q", :query}]
      {plan, _, _} = eval_stmt(~s|v = @Run(m)\nm = Mutation("t", {})|)
      assert plan.steps == [{:run, "m", :mutation}]
      {plan, _, _} = eval_stmt(~s|v = @Run(x)\nx = 1|)
      assert plan.steps == []
    end

    test "@Set and @Reset name their targets" do
      {plan, _, _} = eval_stmt(~s|v = @Set(x, 1)|)
      assert plan.steps == []
      {plan, _, _} = eval_stmt(~s|v = @Reset($a, 1, $b)|)
      assert plan.steps == [{:reset, ["$a", "$b"]}]
      {plan, _, _} = eval_stmt(~s|v = @Reset()|)
      assert plan.steps == []
    end

    test "Action([...]) flattens plans and drops other values" do
      {plan, _, _} = eval_stmt(~s|v = Action([@OpenUrl("u"), 5, Action([@Reset($a)]), null])|)
      assert plan.steps == [{:open_url, "u"}, {:reset, ["$a"]}]
      {plan, _, _} = eval_stmt(~s|v = Action("x")|)
      assert plan.steps == []
    end

    test "a plain list of actions is data" do
      {list, _, _} = eval_stmt(~s|v = [@OpenUrl("a"), @OpenUrl("b")]|)

      assert [%ActionPlan{steps: [{:open_url, "a"}]}, %ActionPlan{steps: [{:open_url, "b"}]}] =
               list
    end
  end

  describe "state defaults (1.1)" do
    defp defaults(program, lib \\ LiveRender.OpenUI.StandardLibrary.library()),
      do: LiveRender.OpenUI.Parser.parse("root = Text(\"x\")\n" <> program, lib).state

    test "an expression default is evaluated once, with the defaults declared before it" do
      state = defaults("$price = 10\n$tax = $price * 0.5\n$total = 1 + 2")
      assert state == %{"$price" => 10, "$tax" => 5.0, "$total" => 3}
    end

    test "a state declared later reads as null" do
      assert defaults("$a = $b + 1\n$b = 5")["$a"] == 1
    end

    test "plain statements are read, query results are null" do
      state =
        defaults(~s|$a = base * 2\nbase = 21\n$q = data.rows\ndata = Query("t", {}, {rows: [1]})|)

      assert state["$a"] == 42
      assert state["$q"] == nil
    end

    test "list and object defaults evaluate each element" do
      assert defaults("$p = 2\n$l = [$p, @Round(2.5), {n: @Count([1, 2])}]")["$l"] ==
               [2, 3, %{"n" => 2}]
    end

    test "a default that calls a library function or an action is null" do
      assert defaults(~s|$a = @Percent(1, 4)|, custom_lib())["$a"] == nil
      assert defaults(~s|$a = [1, @Percent(1, 4)]|, custom_lib())["$a"] == [1, nil]
      assert defaults("$a = Action([@Set($b, 1)])")["$a"] == nil
    end
  end

  describe "evaluation budget" do
    test "a runaway expression stops with runtime-error instead of hanging" do
      # 200^3 = 8 million template evaluations exceed the step budget.
      big = inspect(Enum.to_list(1..200), limit: :infinity)

      program =
        ~s|root = Stack([Text("" + @Count(@Each(a, "x", @Each(a, "y", @Each(a, "z", z)))))])\na = #{big}|

      {time, s} = :timer.tc(fn -> summary(program) end)
      assert time < 5_000_000
      assert Enum.any?(s.errors, &(&1["code"] == "runtime-error"))
    end
  end
end
