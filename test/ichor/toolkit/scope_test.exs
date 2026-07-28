defmodule Ichor.Toolkit.ScopeTest do
  use ExUnit.Case, async: true

  alias Ichor.Toolkit.Scope

  test "a fresh scope has nothing defined" do
    assert Scope.lookup(Scope.new(), :x) == :error
  end

  test "define then lookup finds it" do
    scope = Scope.new() |> Scope.define(:x, 1)
    assert Scope.lookup(scope, :x) == {:ok, 1}
  end

  test "a nested scope sees an outer definition" do
    scope = Scope.new() |> Scope.define(:x, 1) |> Scope.push()
    assert Scope.lookup(scope, :x) == {:ok, 1}
  end

  test "a nested definition shadows the outer one, without touching the outer scope" do
    scope =
      Scope.new()
      |> Scope.define(:x, 1)
      |> Scope.push()
      |> Scope.define(:x, 2)

    assert Scope.lookup(scope, :x) == {:ok, 2}

    popped = Scope.pop(scope)
    assert Scope.lookup(popped, :x) == {:ok, 1}
  end

  test "popping discards only the innermost scope's own bindings" do
    scope =
      Scope.new()
      |> Scope.define(:outer, :o)
      |> Scope.push()
      |> Scope.define(:inner, :i)

    popped = Scope.pop(scope)
    assert Scope.lookup(popped, :outer) == {:ok, :o}
    assert Scope.lookup(popped, :inner) == :error
  end

  test "popping the outermost scope raises -- an unbalanced push/pop is a caller bug" do
    assert_raise FunctionClauseError, fn -> Scope.pop(Scope.new()) end
  end

  test "lookup_local only sees the current scope, not enclosing ones" do
    scope = Scope.new() |> Scope.define(:x, 1) |> Scope.push()
    assert Scope.lookup_local(scope, :x) == :error
    assert Scope.lookup(scope, :x) == {:ok, 1}
  end

  test "redefining within the same scope is allowed and simply overwrites" do
    scope = Scope.new() |> Scope.define(:x, 1) |> Scope.define(:x, 2)
    assert Scope.lookup(scope, :x) == {:ok, 2}
  end

  test "keys can be any term, not just atoms" do
    scope = Scope.new() |> Scope.define("name", :string_key) |> Scope.define({:a, 1}, :tuple_key)
    assert Scope.lookup(scope, "name") == {:ok, :string_key}
    assert Scope.lookup(scope, {:a, 1}) == {:ok, :tuple_key}
  end
end
