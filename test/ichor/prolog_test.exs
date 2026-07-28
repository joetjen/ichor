defmodule Ichor.PrologTest do
  @moduledoc """
  The worked example for track 6 (`Ichor.Backtrack`): a small Prolog
  fragment (`Prolog.DB`, `test/support/prolog.ex`) built entirely on
  `Ichor.Backtrack.Tree`'s search combinators and
  `Ichor.Backtrack.Bindings`' unification, proving actual
  SLD-resolution -- clause selection via `disjunction/2`, subgoal
  sequencing via `conjunction/2`, recursion, laziness, and cut -- works
  end to end over the substrate, with no Ichor core code knowing
  anything about clauses, predicates, or Prolog at all.
  """

  use ExUnit.Case, async: true

  alias Ichor.Backtrack.{Bindings, Tree}
  alias Prolog.{DB, Terms}

  defp resolve_all(solutions, var) do
    solutions |> Tree.to_list() |> Enum.map(&Bindings.resolve(Terms, &1, var))
  end

  describe "parent/2 -- ground facts, disjunction over clauses" do
    test "a query with both arguments ground either succeeds once or fails" do
      assert Tree.to_list(DB.parent([:tom, :bob]).(Bindings.new())) == [Bindings.new()]
      assert Tree.to_list(DB.parent([:tom, :ann]).(Bindings.new())) == []
    end

    test "a query with one variable backtracks through every matching fact, in declared order" do
      y = {:var, make_ref()}
      assert resolve_all(DB.parent([:tom, y]).(Bindings.new()), y) == [:bob, :liz]
      assert resolve_all(DB.parent([:bob, y]).(Bindings.new()), y) == [:ann, :pat]
    end
  end

  describe "grandparent(X, Z) :- parent(X, Y), parent(Y, Z) -- conjunction sequencing subgoals" do
    test "grandparent(tom, W) finds both grandchildren via bob, threading Y through the conjunction" do
      w = {:var, make_ref()}
      assert resolve_all(DB.grandparent([:tom, w]).(Bindings.new()), w) == [:ann, :pat]
    end

    test "grandparent(bob, W) has no solutions -- bob's children have no children of their own here" do
      w = {:var, make_ref()}
      assert DB.grandparent([:bob, w]).(Bindings.new()) |> Tree.to_list() == []
    end
  end

  describe "member(X, List) -- recursive predicate, lazy multiple solutions" do
    test "yields every element, in list order" do
      x = {:var, make_ref()}
      assert resolve_all(DB.member([x, [1, 2, 3]]).(Bindings.new()), x) == [1, 2, 3]
    end

    test "an element not in the list has no solutions" do
      assert DB.member([4, [1, 2, 3]]).(Bindings.new()) |> Tree.to_list() == []
    end

    test "next/1 pulls solutions one at a time without forcing the rest" do
      x = {:var, make_ref()}
      solutions = DB.member([x, [:a, :b, :c]]).(Bindings.new())

      assert {:solution, b1, rest1} = Tree.next(solutions)
      assert Bindings.resolve(Terms, b1, x) == :a

      assert {:solution, b2, rest2} = Tree.next(rest1)
      assert Bindings.resolve(Terms, b2, x) == :b

      assert {:solution, b3, _rest3} = Tree.next(rest2)
      assert Bindings.resolve(Terms, b3, x) == :c
    end
  end

  describe "once/1 -- cut, stops exploring after the first solution" do
    test "parent(bob, Y) alone has two solutions, but once/1 keeps only the first" do
      y = {:var, make_ref()}
      assert resolve_all(DB.parent([:bob, y]).(Bindings.new()), y) == [:ann, :pat]
      assert resolve_all(Tree.once(DB.parent([:bob, y])).(Bindings.new()), y) == [:ann]
    end
  end
end
