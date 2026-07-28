defmodule Ichor.Toolkit.CodegenTest do
  @moduledoc """
  Direct unit tests of `Ichor.Toolkit.Codegen`'s six functions in
  isolation. Its real-world use is proven separately: the refactors of
  `Grammar.Native.CharCompiler`/`RuleCompiler`/`LR` (this module's own
  moduledoc cites each), and the standalone, grammar-unrelated worked
  example in `test/ichor/toolkit/codegen_example_test.exs`
  (`ExprCompiler`, `test/support/expr_compiler.ex`).
  """

  use ExUnit.Case, async: true

  alias Ichor.Toolkit.Codegen

  describe "fresh/2" do
    test "builds a namespaced atom from a string prefix and increments the counter" do
      assert Codegen.fresh("foo_", 0) == {:foo_0, 1}
      assert Codegen.fresh("foo_", 5) == {:foo_5, 6}
    end

    test "accepts an atom prefix too" do
      assert Codegen.fresh(:bar, 2) == {:bar2, 3}
    end
  end

  describe "vars/1" do
    test "builds a map of unhygienic Macro.vars keyed by name" do
      assert Codegen.vars([:a, :b]) == %{a: {:a, [], nil}, b: {:b, [], nil}}
    end

    test "an empty name list builds an empty map" do
      assert Codegen.vars([]) == %{}
    end

    test "two separately-built var maps agree on the same variable for the same name" do
      assert Codegen.vars([:stream]) == Codegen.vars([:stream])
    end
  end

  describe "indexed_vars/3" do
    test "builds a numbered list sharing a base name, starting at 0 by default" do
      assert Codegen.indexed_vars(:x, 3) == [{:x0, [], nil}, {:x1, [], nil}, {:x2, [], nil}]
    end

    test "accepts a custom start" do
      assert Codegen.indexed_vars(:pos, 3, 1) == [
               {:pos1, [], nil},
               {:pos2, [], nil},
               {:pos3, [], nil}
             ]
    end

    test "count 0 returns an empty list" do
      assert Codegen.indexed_vars(:x, 0) == []
    end
  end

  describe "capture/2" do
    test "builds the &name/arity AST for a runtime atom name" do
      assert Codegen.capture(:double, 1) ==
               {:&, [], [{:/, [], [{:double, [], nil}, 1]}]}
    end

    test "the built AST round-trips through Code.eval_quoted as a real, callable function capture" do
      {captured, _bindings} = Code.eval_quoted(Codegen.capture(:abs, 1))
      assert captured.(-5) == 5
    end
  end

  describe "clause/2" do
    test "builds a single pattern -> body clause" do
      assert Codegen.clause(quote(do: x), quote(do: x + 1)) ==
               {:->, [], [[quote(do: x)], quote(do: x + 1)]}
    end

    test "splices into a real case as a working clause" do
      clauses = [Codegen.clause(1, quote(do: :one)), Codegen.clause(2, quote(do: :two))]

      ast =
        quote do
          case unquote(2) do
            unquote(clauses)
          end
        end

      assert {result, _bindings} = Code.eval_quoted(ast)
      assert result == :two
    end
  end

  describe "clause/3" do
    test "builds a guarded pattern when guard -> body clause" do
      pattern = quote(do: x)
      guard = quote(do: x > 0)
      body = quote(do: :positive)

      assert Codegen.clause(pattern, guard, body) ==
               {:->, [], [[{:when, [], [pattern, guard]}], body]}
    end

    test "the guard actually discriminates when spliced into a real case" do
      clause = Codegen.clause(quote(do: x), quote(do: x > 0), quote(do: :positive))
      fallback = Codegen.clause(quote(do: _), quote(do: :non_positive))

      ast =
        quote do
          x = -3

          case x do
            unquote([clause, fallback])
          end
        end

      assert {result, _bindings} = Code.eval_quoted(ast)
      assert result == :non_positive
    end
  end
end
