defmodule LiveRender.OpenUI.StoreTest do
  @moduledoc "The state store (language.md, section 5.1)."

  use ExUnit.Case, async: true

  alias LiveRender.OpenUI.Store

  test "get, has? and put" do
    s = Store.new()
    refute Store.has?(s, "$a")
    assert Store.get(s, "$a") == nil

    s = Store.put(s, "$a", nil)
    assert Store.has?(s, "$a")
    assert Store.snapshot(s) == %{"$a" => nil}
  end

  test "defaults fill missing keys and stay pristine" do
    s = Store.initialize(Store.new(), %{"$a" => 1})
    assert Store.snapshot(s) == %{"$a" => 1}
    assert MapSet.member?(s.pristine, "$a")

    s = Store.initialize(s, %{"$a" => 2})
    assert Store.get(s, "$a") == 2
  end

  test "a written value is never overwritten by defaults" do
    s = Store.new() |> Store.initialize(%{"$a" => 1}) |> Store.put("$a", 5)
    s = Store.initialize(s, %{"$a" => 2})
    assert Store.get(s, "$a") == 5
  end

  test "a value written equal to the default is still the user's" do
    s = Store.new() |> Store.initialize(%{"$a" => 1}) |> Store.put("$a", 1)
    assert Store.get(Store.initialize(s, %{"$a" => 2}), "$a") == 1
  end

  test "a restored default (pristine: true) follows later defaults" do
    s = Store.new() |> Store.put("$a", 5) |> Store.put("$a", 1, pristine: true)
    assert Store.get(Store.initialize(s, %{"$a" => 2}), "$a") == 2
  end

  test "persisted values win over defaults and are not pristine" do
    s = Store.initialize(Store.new(), %{"$a" => 1, "$b" => 2}, %{"$a" => 9})
    assert Store.snapshot(s) == %{"$a" => 9, "$b" => 2}
    refute MapSet.member?(s.pristine, "$a")
    assert Store.get(Store.initialize(s, %{"$a" => 3}), "$a") == 9
  end

  test "initializing never deletes a key" do
    s = Store.new() |> Store.initialize(%{"$a" => 1}) |> Store.put("form", %{})
    s = Store.initialize(s, %{})
    assert Store.snapshot(s) == %{"$a" => 1, "form" => %{}}
  end
end
