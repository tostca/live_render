defmodule LiveRender.OpenUI.JSTest do
  @moduledoc """
  ECMA-262 value semantics (language.md, sections 3.1 and 3.2). Expected values were produced with
  Node.js.
  """

  use ExUnit.Case, async: true

  import LiveRender.OpenUI.TestHelpers, only: [ev: 1]

  alias LiveRender.OpenUI.JS

  describe "Number::toString" do
    for {input, want} <- [
          {0.30000000000000004, "0.30000000000000004"},
          {1.0e21, "1e+21"},
          {9.999_999_999_999_99e20, "999999999999999000000"},
          {1.0e20, "100000000000000000000"},
          {123_456_789_012_345_680_000.0, "123456789012345680000"},
          {1.0e-7, "1e-7"},
          {1.0e-6, "0.000001"},
          {1.5e-7, "1.5e-7"},
          {6.666666666666665e-8, "6.666666666666665e-8"},
          {0.1, "0.1"},
          {-0.0, "0"},
          {0, "0"},
          {-42, "-42"},
          {100.0, "100"},
          {2.5, "2.5"},
          {-1.5e300, "-1.5e+300"},
          {5.0e-324, "5e-324"},
          {1.797_693_134_862_315_7e308, "1.7976931348623157e+308"},
          {9_007_199_254_740_992.0, "9007199254740992"},
          {9_007_199_254_740_994.0, "9007199254740994"},
          {33.333333333333336, "33.333333333333336"},
          {:nan, "NaN"},
          {:infinity, "Infinity"},
          {:neg_infinity, "-Infinity"}
        ] do
      test "#{inspect(input)} -> #{want}" do
        assert JS.number_to_string(JS.normalize(unquote(input))) == unquote(want)
      end
    end

    test "formatting and parsing round-trip for random doubles" do
      :rand.seed(:exsss, {1, 2, 3})

      for _ <- 1..3000 do
        <<f::float-64>> = <<:rand.uniform(0x7FEFFFFFFFFFFFFF)::64>>
        n = JS.normalize(f)
        s = JS.number_to_string(n)
        assert JS.ecma_to_number(s) == n, "#{inspect(f)} printed as #{s}"
      end
    end

    test "integral doubles print without a fraction" do
      assert ev("4 / 2") == 2
      assert JS.number_to_string(ev("4 / 2")) == "2"
      assert ev(~s'"" + 0.5 * 4') == "2"
    end

    test "concatenation prints numbers the JavaScript way" do
      assert ev(~s'"" + (0.1 + 0.2)') == "0.30000000000000004"
      assert ev(~s'"x" + 1e21') == "x1e+21"
      assert ev(~s'"x" + 0.0000001') == "x1e-7"
      assert ev(~s'"x" + 100 / 3') == "x33.333333333333336"
      assert ev(~s'"x" + -0') == "x0"
    end
  end

  describe "StringToNumber" do
    for {input, want} <- [
          {"  12 ", 12},
          {"\t\n 3 \u00a0", 3},
          {"\u2028 7 \u3000", 7},
          {"\ufeff8", 8},
          {"0x1A", 26},
          {"0X1a", 26},
          {"0b101", 5},
          {"0o17", 15},
          {"1e3", 1000},
          {"1E21", 1.0e21},
          {".5", 0.5},
          {"5.", 5},
          {"+.5", 0.5},
          {"-5.", -5},
          {"00012", 12},
          {"0012.50", 12.5},
          {"123e-2", 1.23},
          {"Infinity", :infinity},
          {"+Infinity", :infinity},
          {"-Infinity", :neg_infinity},
          {"1e309", :infinity},
          {"-1e309", :neg_infinity},
          {"1.7976931348623159e308", :infinity},
          {"1e-400", 0},
          {"4.9e-324", 5.0e-324},
          {"1e1000000000", :infinity},
          {"1e-1000000000", 0},
          {"9007199254740993", 9_007_199_254_740_992.0},
          {"", 0},
          {" ", 0},
          {"-0", 0},
          {"1_000", :nan},
          {"1,000", :nan},
          {"infinity", :nan},
          {"-0x1A", :nan},
          {"+0x1A", :nan},
          {"0x", :nan},
          {"0xG", :nan},
          {"0B2", :nan},
          {"1e", :nan},
          {"1e+", :nan},
          {"e5", :nan},
          {".", :nan},
          {"12abc", :nan},
          {"--1", :nan},
          {"1.2.3", :nan},
          {"١٢", :nan}
        ] do
      test "ToNumber(#{inspect(input)})" do
        assert JS.ecma_to_number(unquote(input)) == JS.normalize(unquote(Macro.escape(want)))
      end
    end

    test "toNumber never gives NaN: unparsable strings are 0" do
      assert JS.to_number("1_000") == 0
      assert JS.to_number("abc") == 0
      assert ev(~s'"abc" * 2') == 0
      assert ev(~s'"1_000" + 1') == "1_0001"
      assert ev(~s'"1_000" - 1') == -1
    end

    test "toNumber of other values" do
      assert JS.to_number(true) == 1
      assert JS.to_number(false) == 0
      assert JS.to_number(nil) == 0
      assert JS.to_number([5]) == 0
      assert JS.to_number(%{}) == 0
    end

    test "parseFloat takes the longest prefix" do
      assert JS.parse_float("12abc") == 12
      assert JS.parse_float("  -1.5e3x") == -1500
      assert JS.parse_float("Infinityx") == :infinity
      assert JS.parse_float(".5.6") == 0.5
      assert JS.parse_float("abc") == :nan
      assert JS.parse_float("") == :nan
    end
  end

  describe "IsLooselyEqual" do
    # The value table and every pair that Node.js reports as `==`. Every other pair is not equal.
    @values %{
      "null" => nil,
      "0" => 0,
      "1" => 1,
      "-1" => -1,
      ~s("") => "",
      ~s("0") => "0",
      ~s("1") => "1",
      ~s(" 1 ") => " 1 ",
      ~s("a") => "a",
      "true" => true,
      "false" => false,
      "[]" => [],
      "[1]" => [1],
      "[null]" => [nil],
      "[1,2]" => [1, 2],
      ~s(["1"]) => ["1"],
      "{}" => %{},
      ~s("[object Object]") => "[object Object]",
      ~s("1,2") => "1,2",
      "NaN" => :nan,
      "Infinity" => :infinity,
      ~s("Infinity") => "Infinity",
      ~s("0x10") => "0x10",
      "16" => 16
    }

    @equal MapSet.new([
             {"null", "null"},
             {"0", "0"},
             {"0", ~s("")},
             {"0", ~s("0")},
             {"0", "false"},
             {"0", "[]"},
             {"0", "[null]"},
             {"1", "1"},
             {"1", ~s("1")},
             {"1", ~s(" 1 ")},
             {"1", "true"},
             {"1", "[1]"},
             {"1", ~s(["1"])},
             {"-1", "-1"},
             {~s(""), ~s("")},
             {~s(""), "false"},
             {~s(""), "[]"},
             {~s(""), "[null]"},
             {~s("0"), ~s("0")},
             {~s("0"), "false"},
             {~s("1"), ~s("1")},
             {~s("1"), "true"},
             {~s("1"), "[1]"},
             {~s("1"), ~s(["1"])},
             {~s(" 1 "), ~s(" 1 ")},
             {~s(" 1 "), "true"},
             {~s("a"), ~s("a")},
             {"true", "true"},
             {"false", "false"},
             {"false", "[]"},
             {"false", "[null]"},
             {"[1]", "true"},
             {~s(["1"]), "true"},
             {"[1,2]", ~s("1,2")},
             {"{}", ~s("[object Object]")},
             {~s("[object Object]"), ~s("[object Object]")},
             {~s("1,2"), ~s("1,2")},
             {"Infinity", "Infinity"},
             {"Infinity", ~s("Infinity")},
             {~s("Infinity"), ~s("Infinity")},
             {~s("0x10"), "16"},
             {~s("0x10"), ~s("0x10")},
             {"16", "16"}
           ])

    test "the matrix matches JavaScript" do
      for {a, x} <- @values, {b, y} <- @values do
        # Two evaluated arrays or objects are never the same reference (ADR 0001).
        both_objects? = (is_list(x) or is_map(x)) and (is_list(y) or is_map(y))

        want =
          not both_objects? and (MapSet.member?(@equal, {a, b}) or MapSet.member?(@equal, {b, a}))

        assert JS.loose_equal?(x, y) == want, "#{a} == #{b} should be #{want}"
      end
    end

    test "in expressions" do
      assert ev("[1] == 1")
      assert ev(~s'[] == ""')
      assert ev("[] == false")
      assert ev(~s'5 == "5"')
      refute ev("null == 0")
      refute ev("null == false")
      assert ev("null == null")
      assert ev("$unset == null")
      refute ev("[1] == [1]")
      assert ev(~s'[1, 2] != "1, 2"')
    end
  end

  describe "truthiness" do
    test "ToBoolean" do
      for falsy <- [nil, false, 0, 0.0, -0.0, "", :nan] do
        refute JS.truthy?(falsy), inspect(falsy)
      end

      for truthy <- [true, 1, -1, "0", "false", " ", [], %{}, [nil], :infinity, :neg_infinity] do
        assert JS.truthy?(truthy), inspect(truthy)
      end
    end

    test "! and the short-circuit operators" do
      assert ev("!![]") == true
      assert ev(~s'!!""') == false
      assert ev(~s'!!"0"') == true
      assert ev(~s'0 || "x"') == "x"
      assert ev(~s'"" && "x"') == ""
      assert ev(~s'1 && "x"') == "x"
      assert ev("null || null") == nil
      # Short-circuit: the right side is not evaluated.
      assert ev("1 || @Nope()") == 1
    end

    test "a component instance is truthy and acts like an object" do
      assert ev(~s'Text("a") ? "yes" : "no"') == "yes"
      assert ev(~s'-Text("a")') == 0
      assert ev(~s'Text("a").text') == nil
      assert ev(~s'"" + Text("a")') == "[object Object]"
    end
  end

  describe "operators" do
    test "+ joins when either side is a string, null becomes empty" do
      assert ev(~s'"a" + null') == "a"
      assert ev(~s'null + "a"') == "a"
      assert ev(~s'"a" + $unset') == "a"
      assert ev(~s'"a" + true') == "atrue"
      assert ev(~s'"a" + [1, [2, 3]]') == "a1,2,3"
      assert ev(~s'"a" + [null, 1]') == "a,1"
      assert ev(~s'"a" + {}') == "a[object Object]"
      assert ev(~s'1 + 2 + "x"') == "3x"
      assert ev(~s'"x" + 1 + 2') == "x12"
    end

    test "+ without strings adds with toNumber" do
      assert ev("null + 1") == 1
      assert ev("true + true") == 2
      assert ev("[1] + 1") == 1
      assert ev("{} + 1") == 1
    end

    test "division and modulo by zero give 0" do
      assert ev("1 / 0") == 0
      assert ev("-1 / 0") == 0
      assert ev("0 / 0") == 0
      assert ev("5 % 0") == 0
      assert ev(~s'5 / "0"') == 0
      assert ev(~s'5 / "abc"') == 0
      assert ev("5 / null") == 0
    end

    test "modulo keeps the dividend's sign" do
      assert ev("-5 % 3") == -2
      assert ev("5 % -3") == 2
      assert ev("5.5 % 2") == 1.5
      assert ev("-5.5 % 2") == -1.5
    end

    test "Infinity arithmetic" do
      assert ev(~s'"Infinity" * 1') == :infinity
      assert ev(~s'-"Infinity"') == :neg_infinity
      assert ev(~s'"Infinity" + 1') == "Infinity1"
      assert ev(~s'"Infinity" - 1') == :infinity
      assert ev(~s'"Infinity" - "Infinity"') == :nan
      assert ev(~s'"Infinity" * 0') == :nan
      assert ev(~s'1 / "Infinity"') == 0
      assert ev(~s'"Infinity" / "Infinity"') == :nan
      assert ev(~s'"Infinity" % 2') == :nan
      assert ev(~s'5 % "Infinity"') == 5
      assert ev(~s'"Infinity" > 1e308') == true
      assert ev(~s'"" + "Infinity" * -1') == "-Infinity"
      assert ev("1e308 * 10") == :infinity
      assert ev("-1e308 * 10") == :neg_infinity
      assert ev("1e308 + 1e308") == :infinity
    end

    test "comparisons use toNumber on both sides" do
      assert ev(~s'"5" > "10"') == false
      assert ev(~s'"10" > "5"') == true
      assert ev(~s'3 >= "3"') == true
      assert ev(~s'"abc" <= 0') == true
      assert ev("null < 1") == true
      assert ev("[2] > 1") == false
    end

    test "unary minus negates toNumber" do
      assert ev(~s'-"3"') == -3
      assert ev("-null") == 0
      assert ev("-true") == -1
      assert ev("--2") == 2
      assert ev("!-0") == true
    end
  end
end
