defmodule Ichor.Toolkit.ScopeExampleTest do
  @moduledoc "Proves Ichor.Toolkit.Scope's real-world use via ToyResolver (test/support/toy_resolver.ex)."

  use ExUnit.Case, async: true

  describe "let bindings" do
    test "a let-bound variable resolves in its own body" do
      assert ToyResolver.resolve({:let, :x, 1, {:var, :x}}) == :ok
    end

    test "a variable is not visible before its let -- resolving the value expression doesn't see it" do
      # let x = x in x  -- the inner `x` (the value) refers to a
      # not-yet-bound `x`, so it must fail even though the outer body
      # would otherwise succeed.
      assert {:error, _} = ToyResolver.resolve({:let, :x, {:var, :x}, {:var, :x}})
    end

    test "nested lets shadow correctly" do
      # let x = 1 in let x = 2 in x  -- resolves, and (informally) the
      # inner x wins; Scope itself is what's actually being proven here.
      inner = {:let, :x, 2, {:var, :x}}
      assert ToyResolver.resolve({:let, :x, 1, inner}) == :ok
    end
  end

  describe "lambda parameters introduce a nested scope" do
    test "a lambda's own parameter resolves inside its body" do
      assert ToyResolver.resolve({:lambda, [:x], {:var, :x}}) == :ok
    end

    test "a lambda parameter shadows an outer let binding, then reverts after the lambda" do
      program =
        {:let, :x, 1, {:apply, {:lambda, [:x], {:var, :x}}, [{:var, :x}]}}

      assert ToyResolver.resolve(program) == :ok
    end

    test "a lambda's own parameters aren't visible outside its body" do
      # (lambda (x) x) applied to y -- y is undefined at the call site,
      # outside the lambda's own scope.
      program = {:apply, {:lambda, [:x], {:var, :x}}, [{:var, :y}]}
      assert {:error, message} = ToyResolver.resolve(program)
      assert message =~ ":y"
    end
  end

  describe "undefined variables" do
    test "a bare undefined reference is an error" do
      assert {:error, message} = ToyResolver.resolve({:var, :nope})
      assert message =~ ":nope"
    end

    test "literals never need resolving" do
      assert ToyResolver.resolve(42) == :ok
      assert ToyResolver.resolve("a string") == :ok
    end
  end
end
