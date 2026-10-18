defmodule LiveRender.OpenUI.RulesTest do
  @moduledoc "Validation rules (language.md, section 5.4)."

  use ExUnit.Case, async: true

  alias LiveRender.OpenUI.Rules

  defp v(value, rules), do: Rules.validate(value, rules)

  describe "required" do
    test "fails on every empty value" do
      for empty <- [nil, "", [], %{}] do
        assert v(empty, %{"required" => true}) == "This field is required"
      end
    end

    test "passes present values, including falsy ones" do
      for value <- ["x", " ", 0, false, [1], %{"a" => 1}] do
        assert v(value, %{"required" => true}) == nil, inspect(value)
      end
    end

    test "a form field wrapper is read by its value" do
      assert v(%{"value" => "", "componentType" => "input"}, %{"required" => true})
      refute v(%{"value" => "x", "componentType" => "input"}, %{"required" => true})
    end

    # Checkbox groups store {option: bool}; the reference requires one checked option.
    test "an object of booleans needs one true" do
      assert v(%{"a" => false, "b" => false}, %{"required" => true}) ==
               "At least one option is required"

      refute v(%{"a" => false, "b" => true}, %{"required" => true})
    end
  end

  describe "every other rule skips empty values" do
    test "null, empty string, empty array and empty object pass" do
      rules = %{
        "email" => true,
        "url" => true,
        "numeric" => true,
        "minLength" => 3,
        "maxLength" => 0,
        "min" => 5,
        "max" => -1,
        "pattern" => "^x$"
      }

      for empty <- [nil, "", [], %{}] do
        assert v(empty, rules) == nil, inspect(empty)
      end
    end
  end

  describe "email" do
    test "checks local@domain.tld with no spaces" do
      refute v("a@b.co", %{"email" => true})
      refute v("first.last+tag@sub.example.org", %{"email" => true})

      for bad <- ["a b@c.d", "a@b", "@b.co", "a@.co", "a@b.co ", 42] do
        assert v(bad, %{"email" => true}) == "Please enter a valid email", inspect(bad)
      end
    end
  end

  describe "url" do
    test "needs an absolute URL with a scheme and a host" do
      for ok <- ["https://openui.com/x", "http://localhost:4000", "ftp://h.example/f"] do
        refute v(ok, %{"url" => true}), ok
      end

      for bad <- ["openui.com", "/relative", "mailto:a@b.co", "http://", "not a url", 1] do
        assert v(bad, %{"url" => true}) == "Please enter a valid URL", inspect(bad)
      end
    end
  end

  describe "numeric" do
    test "numbers and strings parseFloat accepts pass" do
      for ok <- [3, -1.5, "12abc", " 7", "1e3", ".5", "Infinity"] do
        refute v(ok, %{"numeric" => true}), inspect(ok)
      end

      for bad <- ["abc", " ", "x1", true, ["1"]] do
        assert v(bad, %{"numeric" => true}) == "Must be a number", inspect(bad)
      end
    end
  end

  describe "lengths" do
    test "count UTF-16 code units, like JavaScript" do
      assert v("ab", %{"minLength" => 3}) == "Must be at least 3 characters"
      refute v("abc", %{"minLength" => 3})
      # One emoji is two UTF-16 code units.
      refute v("😀a", %{"minLength" => 3})
      assert v("😀😀", %{"maxLength" => 3}) == "Must be no more than 3 characters"
      refute v("abc", %{"maxLength" => 3})
    end

    test "do not apply to non-strings" do
      refute v([1], %{"minLength" => 3})
      refute v(12345, %{"maxLength" => 3})
    end
  end

  describe "min and max" do
    test "compare numbers and numeric strings" do
      assert v(4, %{"min" => 5}) == "Must be at least 5"
      refute v(5, %{"min" => 5})
      assert v("4", %{"min" => 5}) == "Must be at least 5"
      refute v(5, %{"max" => 5})
      assert v("5.5", %{"max" => 5}) == "Must be no more than 5"
      assert v(-1, %{"min" => 0.5}) == "Must be at least 0.5"
    end

    test "skip values that are not numbers" do
      refute v("abc", %{"min" => 5})
      refute v("abc", %{"max" => 5})
    end
  end

  describe "pattern" do
    test "matches the whole value only when anchored" do
      refute v("AB123", %{"pattern" => "^[A-Z]{2}\\d{3}$"})
      assert v("ab123", %{"pattern" => "^[A-Z]{2}\\d{3}$"}) == "Invalid format"
      refute v("xxABxx", %{"pattern" => "AB"})
      refute v("b", %{"pattern" => "^(a|b)$"})
    end

    test "an invalid pattern passes, as in the reference client" do
      refute v("x", %{"pattern" => "(["})
    end

    test "a pattern that is not a string, or a value that is not, passes" do
      refute v("x", %{"pattern" => 5})
      refute v(5, %{"pattern" => "^x$"})
    end

    test "catastrophic patterns return instead of hanging" do
      assert v(String.duplicate("a", 40) <> "!", %{"pattern" => "^(a+)+$"}) in [
               nil,
               "Invalid format"
             ]
    end
  end

  describe "rule selection" do
    test "the first failing rule gives the error, in the order of section 5.4" do
      assert v("nope", %{"required" => true, "email" => true}) == "Please enter a valid email"
      assert v("", %{"email" => true, "required" => true}) == "This field is required"
      assert v("ab", %{"pattern" => "^z", "minLength" => 3}) == "Must be at least 3 characters"
    end

    test "a rule set to false or null is off; unknown rules pass" do
      refute v("", %{"required" => false})
      refute v("", %{"required" => nil})
      refute v("x", %{"bogus" => true})
    end

    test "no rules, or rules that are not an object, pass" do
      refute v("", nil)
      refute v("", "required")
      refute v("", %{})
    end
  end

  test "empty?/1" do
    assert Rules.empty?(nil)
    assert Rules.empty?(%{"value" => [], "componentType" => "x"})
    refute Rules.empty?(0)
    refute Rules.empty?(" ")
  end
end
