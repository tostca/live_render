defmodule LiveRender.OpenUI.LexerTest do
  @moduledoc "Lexical elements (language.md, section 1.3)."

  use ExUnit.Case, async: true

  alias LiveRender.OpenUI.{ExprParser, Lexer, Statements}

  defp toks(src), do: src |> Lexer.tokenize() |> Enum.map(fn {k, v, _} -> {k, v} end)
  # Builds escapes without writing backslash-u sequences in this file: `%` becomes a backslash.
  defp bs(s), do: String.replace(s, "%", "\\")

  defp kinds(src), do: src |> Lexer.tokenize() |> Enum.map(&elem(&1, 0))

  defp expr(src) do
    [raw | _] = ("x = " <> src) |> Lexer.tokenize() |> Statements.split()
    ExprParser.parse(raw.tokens)
  end

  describe "minus versus negative numbers" do
    test "a minus starts a number only after a non-value" do
      assert toks("-1") == [num: -1]
      assert toks("[1 -2]") == [lbrack: nil, num: 1, minus: nil, num: 2, rbrack: nil]
      assert toks("(-2)") == [lparen: nil, num: -2, rparen: nil]
      assert toks("a -1") == [ident: "a", minus: nil, num: 1]
      assert toks("A -1") == [type: "A", minus: nil, num: 1]
      assert toks("$a -1") == [state: "$a", minus: nil, num: 1]
      assert toks("@a -1") == [builtin: "a", minus: nil, num: 1]
      assert toks(~s("s" -1)) == [str: "s", minus: nil, num: 1]
      assert toks("true -1") == [true: true, minus: nil, num: 1]
      assert toks("false -1") == [false: false, minus: nil, num: 1]
      assert toks("null -1") == [null: nil, minus: nil, num: 1]
      assert toks(") -1") == [rparen: nil, minus: nil, num: 1]
      assert toks("] -1") == [rbrack: nil, minus: nil, num: 1]
    end

    test "`}` is not a value, so a minus after it starts a number" do
      assert toks("} -1") == [rbrace: nil, num: -1]
      assert toks(", -1") == [comma: nil, num: -1]
      assert toks("= -1") == [equals: nil, num: -1]
      assert toks("? -1 : -2") == [question: nil, num: -1, colon: nil, num: -2]
    end

    test "a minus not followed by a digit is an operator" do
      assert toks("-a") == [minus: nil, ident: "a"]
      assert toks("- 1") == [minus: nil, num: 1]
      assert toks("--1") == [minus: nil, num: -1]
    end

    test "parsed meaning" do
      assert expr("[1 -2]") == {:arr, [{:bin, "-", {:num, 1}, {:num, 2}}]}
      assert expr("[1, -2]") == {:arr, [{:num, 1}, {:num, -2}]}
      assert expr("[1 - -2]") == {:arr, [{:bin, "-", {:num, 1}, {:num, -2}}]}
      assert expr("a-1") == {:bin, "-", {:ref, "a"}, {:num, 1}}
      assert expr("-(1)") == {:unary, "-", {:num, 1}}
      assert expr("!!x") == {:unary, "!", {:unary, "!", {:ref, "x"}}}
      assert expr("- -x") == {:unary, "-", {:unary, "-", {:ref, "x"}}}
    end
  end

  describe "numbers" do
    test "a dot is part of a number only when a digit follows" do
      assert toks("1.5") == [num: 1.5]
      assert toks("1.") == [num: 1, dot: nil]
      assert toks("1.x") == [num: 1, dot: nil, ident: "x"]
      assert expr("1.foo") == {:member, {:num, 1}, "foo"}
      assert expr("1.5.x") == {:member, {:num, 1.5}, "x"}
      assert toks(".5") == [dot: nil, num: 5]
    end

    test "exponents" do
      assert toks("2E3") == [num: 2000]
      assert toks("2e+3") == [num: 2000]
      assert toks("2e-3") == [num: 0.002]
      assert toks("1.5e1") == [num: 15]
      assert toks("1e21") == [num: 1.0e21]
      assert toks("1e400") == [num: :infinity]
      assert toks("-1e400") == [num: :neg_infinity]
      assert toks("1.8e308") == [num: :infinity]
    end

    test "an e after the digits is always an exponent marker, even with nothing after it" do
      # The value of a dangling exponent is implementation-defined; we follow `+"1e"` (NaN).
      assert toks("1e") == [num: :nan]
      assert toks("1e+") == [num: :nan]
      assert toks("1ex") == [num: :nan, ident: "x"]
      assert toks("1e+x") == [num: :nan, ident: "x"]
      assert toks("1E-") == [num: :nan]
    end

    test "large integers are doubles" do
      assert toks("9007199254740993") == [num: 9_007_199_254_740_992.0]
      assert toks("12345678901234567890123") == [num: 1.234_567_890_123_456_8e22]
    end
  end

  describe "double-quoted strings" do
    test "JSON escapes" do
      assert toks(~S("a\nb\tc\"d\\e\/f\bg\fh\ri")) == [str: "a\nb\tc\"d\\e/f\bg\fh\ri"]
      assert toks(bs(~S("%u00e9%u4e2d"))) == [str: "é中"]
    end

    test "surrogate pairs combine into one character" do
      assert toks(bs(~S("%ud83d%ude00"))) == [str: "😀"]
      assert toks(bs(~S("%uD83D%uDE00!"))) == [str: "😀!"]
    end

    test "lone surrogates become the replacement character" do
      assert toks(bs(~S("%ud83d"))) == [str: "\uFFFD"]
      assert toks(bs(~S("%ude00x"))) == [str: "\uFFFDx"]
      assert toks(bs(~S("%ud83dx"))) == [str: "\uFFFDx"]
    end

    test "text that is not valid JSON keeps its raw content" do
      assert toks(~S("bad \q escape")) == [str: ~S(bad \q escape)]
      assert toks(bs(~S("%u12"))) == [str: bs("%u12")]
      assert toks(~s("raw\nnewline")) == [str: "raw\nnewline"]
    end

    test "comment markers and quotes of the other kind are plain text" do
      assert toks(~s("a // b # c 'd'")) == [str: "a // b # c 'd'"]
    end

    test "an unterminated string runs to the end" do
      assert toks(~s("abc)) == [str: "abc"]
      assert toks(~s("abc\\)) == [str: "abc\\"]
    end

    test "multi-byte characters pass through" do
      assert toks(~s("émoji 😀 中文")) == [str: "émoji 😀 中文"]
    end
  end

  describe "single-quoted strings" do
    test "only \\', \\\\, \\n and \\t are escapes; others keep the character" do
      assert toks(~S('it\'s')) == [str: "it's"]
      assert toks(~S('a\\b')) == [str: "a\\b"]
      assert toks(~S('a\nb\tc')) == [str: "a\nb\tc"]
      assert toks(~S('a\qb')) == [str: "aqb"]
      assert toks(~S('a\"b')) == [str: "a\"b"]
      assert toks(bs(~S('%u00e9'))) == [str: "u00e9"]
    end

    test "double quotes inside need no escape" do
      assert toks(~S('say "hi"')) == [str: ~S(say "hi")]
    end

    test "an unterminated single-quoted string runs to the end" do
      assert toks("'abc") == [str: "abc"]
      assert toks("'abc\\") == [str: "abc"]
    end
  end

  describe "names" do
    test "identifiers, components, state and @ names" do
      assert toks("abc _x A1 $s_1 @Fn @lower") ==
               [
                 ident: "abc",
                 ident: "_x",
                 type: "A1",
                 state: "$s_1",
                 builtin: "Fn",
                 builtin: "lower"
               ]
    end

    test "keywords" do
      assert kinds("true false null True nullx") == [true, false, :null, :type, :ident]
    end

    test "a $ or @ without a name is skipped" do
      assert toks("$ 1") == [num: 1]
      assert toks("@1") == [num: 1]
      assert toks("$1a") == [num: 1, ident: "a"]
    end
  end

  describe "operators and punctuation" do
    test "every operator" do
      assert kinds("= == != > < >= <= + - * / % && || ! ? : . , ( ) [ ] { }") ==
               [:equals, :eqeq, :noteq, :gt, :lt, :gte, :lte, :plus, :minus, :star, :slash] ++
                 [:percent, :and, :or, :not, :question, :colon, :dot, :comma, :lparen, :rparen] ++
                 [:lbrack, :rbrack, :lbrace, :rbrace]
    end

    test "a single & or | means && or ||" do
      assert kinds("a & b | c") == [:ident, :and, :ident, :or, :ident]
      assert kinds("a &&& b") == [:ident, :and, :and, :ident]

      assert expr("x & y | z") ==
               {:bin, "||", {:bin, "&&", {:ref, "x"}, {:ref, "y"}}, {:ref, "z"}}
    end

    test "=== lexes as == then =" do
      assert kinds("a === b") == [:ident, :eqeq, :equals, :ident]
    end
  end

  describe "whitespace and unknown characters" do
    test "unknown characters are skipped" do
      assert toks("a;b") == [ident: "a", ident: "b"]
      assert toks("a ~ ^ \\ ` b") == [ident: "a", ident: "b"]
      assert toks("é😀a") == [ident: "a"]
    end

    test "\\r before \\n is consumed with it; a lone \\r is whitespace" do
      assert kinds("a\r\nb") == [:ident, :newline, :ident]
      assert kinds("a\rb") == [:ident, :ident]
    end

    test "offsets are byte offsets" do
      assert [{:ident, "a", 0}, {:str, "é", 2}, {:ident, "b", 7}] = Lexer.tokenize(~s(a "é" b))
      assert [{:ident, "x", 10}] = Lexer.tokenize("x", 10)
    end

    test "lexing never fails on arbitrary bytes" do
      :rand.seed(:exsss, {3, 4, 5})

      for _ <- 1..2000 do
        bin = :crypto.strong_rand_bytes(:rand.uniform(64))
        assert is_list(Lexer.tokenize(bin))
      end
    end
  end

  describe "expressions" do
    test "precedence from lowest to highest" do
      assert expr("a || b && c") ==
               {:bin, "||", {:ref, "a"}, {:bin, "&&", {:ref, "b"}, {:ref, "c"}}}

      assert expr("a == b < c") ==
               {:bin, "==", {:ref, "a"}, {:bin, "<", {:ref, "b"}, {:ref, "c"}}}

      assert expr("a + b * c") == {:bin, "+", {:ref, "a"}, {:bin, "*", {:ref, "b"}, {:ref, "c"}}}
      assert expr("-a.b") == {:unary, "-", {:member, {:ref, "a"}, "b"}}
      assert expr("!a == b") == {:bin, "==", {:unary, "!", {:ref, "a"}}, {:ref, "b"}}
    end

    test "binary operators are left-associative" do
      assert expr("a - b - c") == {:bin, "-", {:bin, "-", {:ref, "a"}, {:ref, "b"}}, {:ref, "c"}}
      assert expr("a / b * c") == {:bin, "*", {:bin, "/", {:ref, "a"}, {:ref, "b"}}, {:ref, "c"}}
    end

    test "the ternary is right-associative and lowest" do
      assert expr("a ? b : c ? d : e") ==
               {:ternary, {:ref, "a"}, {:ref, "b"},
                {:ternary, {:ref, "c"}, {:ref, "d"}, {:ref, "e"}}}

      assert expr("a || b ? c : d") ==
               {:ternary, {:bin, "||", {:ref, "a"}, {:ref, "b"}}, {:ref, "c"}, {:ref, "d"}}

      assert expr("a ? b ? c : d : e") ==
               {:ternary, {:ref, "a"}, {:ternary, {:ref, "b"}, {:ref, "c"}, {:ref, "d"}},
                {:ref, "e"}}
    end

    test "object keys" do
      assert expr(~s({a: 1, "b c": 2, 3: 3, Foo: 4, $s: 5, true: 6, 1.5: 7})) ==
               {:obj,
                [
                  {"a", {:num, 1}},
                  {"b c", {:num, 2}},
                  {"3", {:num, 3}},
                  {"Foo", {:num, 4}},
                  {"s", {:num, 5}},
                  {"?", {:num, 6}},
                  {"1.5", {:num, 7}}
                ]}
    end

    test "commas are optional and trailing commas ignored" do
      assert expr("[1 2, 3,]") == {:arr, [{:num, 1}, {:num, 2}, {:num, 3}]}
      assert expr("{a: 1 b: 2,}") == {:obj, [{"a", {:num, 1}}, {"b", {:num, 2}}]}
      assert {:call, "Text", [{:str, "a"}, {:str, "b"}], false, nil} = expr(~s{Text("a" "b",)})
    end

    test "member fields accept key tokens; a number after a dot is a field" do
      assert expr("m.0") == {:member, {:ref, "m"}, "0"}
      assert expr("m.0.1") == {:member, {:ref, "m"}, "0.1"}
      assert expr("m.Foo.$bar") == {:member, {:member, {:ref, "m"}, "Foo"}, "bar"}
      assert expr(~s(m."a b")) == {:member, {:ref, "m"}, "a b"}
      assert expr("m[0][1]") == {:index, {:index, {:ref, "m"}, {:num, 0}}, {:num, 1}}
    end

    test "a member access is never callable" do
      assert expr("foo.bar(x)") == {:member, {:ref, "foo"}, "bar"}
    end

    test "built-ins need the @; only Action works without it" do
      assert expr("Count(x)") == {:ref, "Count"}
      assert {:call, "Count", [{:ref, "x"}], false, nil} = expr("@Count(x)")
      assert {:call, "Action", [{:arr, []}], false, nil} = expr("Action([])")
      assert {:call, "Action", [{:arr, []}], false, nil} = expr("@Action([])")
    end

    test "the @ name may be lowercase; an unknown one is a function call" do
      assert {:call, "count", [{:ref, "x"}], true, nil} = expr("@count(x)")
    end

    test "a bare identifier is a reference whatever its case" do
      assert expr("Header") == {:ref, "Header"}
    end

    test "a binding assignment inside an expression" do
      assert expr("$x = 5") == {:assign, "$x", {:num, 5}}
    end

    test "trailing tokens after a complete expression are ignored" do
      assert expr("1 2 3") == {:num, 1}
      assert expr("a b") == {:ref, "a"}
    end

    test "unexpected tokens read as null" do
      assert expr(")") == {:null}
      assert expr("[,]") == {:arr, [{:null}]}
      assert expr("1 +") == {:bin, "+", {:num, 1}, {:null}}
    end
  end
end
