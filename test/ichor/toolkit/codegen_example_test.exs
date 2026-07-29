defmodule Ichor.Toolkit.CodegenExampleTest do
  @moduledoc """
  Proves `Ichor.Toolkit.Codegen`'s helpers work outside Ichor's own
  grammar/capture-tree domain entirely, via `ExprCompiler`
  (`test/support/expr_compiler.ex`) and its `ExprCompiler.Example`
  instantiation -- a tiny expression-to-Elixir-function compiler with no
  grammar concepts anywhere in it.
  """

  use ExUnit.Case, async: true

  describe "the true branch: map_sum over a doubled list, via capture/2" do
    test "doubles every element and sums" do
      assert ExprCompiler.Example.run(%{flag: true, xs: [1, 2, 3]}) == 12
    end

    test "an empty list sums to 0" do
      assert ExprCompiler.Example.run(%{flag: true, xs: []}) == 0
    end
  end

  describe "the false branch: sum/add/mul over env-bound variables, via indexed_vars/3" do
    test "1 + (a + 2) + (a * 3), with a = 5" do
      assert ExprCompiler.Example.run(%{flag: false, a: 5}) == 1 + (5 + 2) + 5 * 3
    end

    test "1 + (a + 2) + (a * 3), with a = 0" do
      assert ExprCompiler.Example.run(%{flag: false, a: 0}) == 1 + (0 + 2) + 0 * 3
    end
  end

  describe "switch dispatch itself, via clause/2" do
    test "flag selects which branch runs, not just which value is returned" do
      refute ExprCompiler.Example.run(%{flag: true, xs: [10]}) ==
               ExprCompiler.Example.run(%{flag: false, a: 10})
    end
  end
end
