defmodule Ichor.BacktrackTest do
  use ExUnit.Case, async: true

  alias Ichor.Backtrack.{Bindings, Tree}

  defmodule Terms do
    @moduledoc "A minimal Ichor.Backtrack.Term for these tests: {:var, ref} variables, {:compound, functor, args} compounds, anything else atomic."
    @behaviour Ichor.Backtrack.Term

    @impl true
    def variable?({:var, _id}), do: true
    def variable?(_), do: false

    @impl true
    def var_id({:var, id}), do: id

    @impl true
    def compound?({:compound, _f, _args}), do: true
    def compound?(_), do: false

    @impl true
    def deconstruct({:compound, f, args}), do: {f, args}
  end

  describe "Tree: unit/fail" do
    test "unit succeeds exactly once, with bindings unchanged" do
      solutions = Tree.unit().(:some_bindings)
      assert Tree.next(solutions) == {:solution, :some_bindings, Tree.empty()}
      assert Tree.next(Tree.empty()) == :empty
    end

    test "fail never succeeds" do
      assert Tree.next(Tree.fail().(:anything)) == :empty
    end
  end

  describe "Tree: disjunction" do
    test "yields every solution of the first goal, then every solution of the second, in order" do
      g1 = fn b -> Tree.of_one({:g1, b}) end
      g2 = fn b -> Tree.of_one({:g2, b}) end

      assert Tree.disjunction(g1, g2).(:b) |> Tree.to_list() == [{:g1, :b}, {:g2, :b}]
    end

    test "both branches start from the same bindings, not threaded" do
      g1 = Tree.fail()
      g2 = fn b -> Tree.of_one({:only, b}) end
      assert Tree.disjunction(g1, g2).(:start) |> Tree.to_list() == [only: :start]
    end
  end

  describe "Tree: conjunction" do
    test "threads each solution of the first goal into the second" do
      g1 = fn b -> Tree.of_one(b + 1) end
      g2 = fn b -> Tree.of_one(b * 10) end
      assert Tree.conjunction(g1, g2).(1) |> Tree.to_list() == [20]
    end

    test "multiple solutions of the first goal each feed the second, concatenated in order" do
      multi = fn b -> Tree.concat(Tree.of_one(b + 1), Tree.of_one(b + 2)) end
      g2 = fn b -> Tree.of_one(b * 10) end
      assert Tree.conjunction(multi, g2).(0) |> Tree.to_list() == [10, 20]
    end

    test "a failing first goal short-circuits, never touching the second" do
      assert Tree.conjunction(Tree.fail(), Tree.fail()).(:b) |> Tree.to_list() == []
    end
  end

  describe "Tree: once" do
    test "takes only the first solution, even when more exist" do
      multi = fn b -> Tree.concat(Tree.of_one(b), Tree.concat(Tree.of_one(b), Tree.of_one(b))) end
      assert Tree.once(multi).(:x) |> Tree.to_list() == [:x]
    end

    test "genuinely never explores past the first solution -- a goal that would raise past its first result is safe" do
      lazy_tail = fn -> raise "should never be forced" end

      infinite_ish = fn _b ->
        fn -> {:solution, :first, lazy_tail} end
      end

      assert Tree.once(infinite_ish).(:x) |> Tree.to_list() == [:first]
    end
  end

  describe "Bindings: resolve/bind" do
    test "an unbound variable resolves to itself" do
      x = {:var, make_ref()}
      assert Bindings.resolve(Terms, Bindings.new(), x) == x
    end

    test "a bound variable resolves through however many hops it takes" do
      a = {:var, make_ref()}
      b = {:var, make_ref()}

      bindings =
        Bindings.new()
        |> Bindings.bind(Terms.var_id(a), b)
        |> Bindings.bind(Terms.var_id(b), 42)

      assert Bindings.resolve(Terms, bindings, a) == 42
    end

    test "an atomic term resolves to itself" do
      assert Bindings.resolve(Terms, Bindings.new(), :atom) == :atom
    end
  end

  describe "Bindings: unify" do
    test "two identical atoms unify without extending bindings" do
      assert Bindings.unify(Terms, Bindings.new(), :tom, :tom) == {:ok, Bindings.new()}
    end

    test "two different atoms fail to unify" do
      assert Bindings.unify(Terms, Bindings.new(), :tom, :bob) == :fail
    end

    test "an unbound variable unifies with anything, binding it" do
      x = {:var, make_ref()}
      assert {:ok, bindings} = Bindings.unify(Terms, Bindings.new(), x, 42)
      assert Bindings.resolve(Terms, bindings, x) == 42
    end

    test "two unbound variables unify with each other, binding one to the other" do
      x = {:var, make_ref()}
      y = {:var, make_ref()}
      assert {:ok, bindings} = Bindings.unify(Terms, Bindings.new(), x, y)
      bindings = Bindings.bind(bindings, Terms.var_id(y), :resolved)
      assert Bindings.resolve(Terms, bindings, x) == :resolved
    end

    test "compound terms unify when functor/arity match and every argument unifies" do
      x = {:var, make_ref()}
      a = {:compound, :pair, [1, x]}
      b = {:compound, :pair, [1, 2]}
      assert {:ok, bindings} = Bindings.unify(Terms, Bindings.new(), a, b)
      assert Bindings.resolve(Terms, bindings, x) == 2
    end

    test "compound terms with a mismatched functor or arity fail to unify" do
      assert Bindings.unify(
               Terms,
               Bindings.new(),
               {:compound, :pair, [1, 2]},
               {:compound, :triple, [1, 2]}
             ) ==
               :fail

      assert Bindings.unify(
               Terms,
               Bindings.new(),
               {:compound, :pair, [1, 2]},
               {:compound, :pair, [1, 2, 3]}
             ) ==
               :fail
    end

    test "compound terms with a mismatched argument fail to unify, even if an earlier argument bound a variable" do
      x = {:var, make_ref()}
      a = {:compound, :pair, [x, 2]}
      b = {:compound, :pair, [1, 3]}
      assert Bindings.unify(Terms, Bindings.new(), a, b) == :fail
    end

    test "no occurs-check: a variable unifying with a compound containing itself just binds (matches ISO Prolog's default)" do
      x = {:var, make_ref()}
      cyclic = {:compound, :f, [x]}
      assert {:ok, bindings} = Bindings.unify(Terms, Bindings.new(), x, cyclic)
      assert Bindings.resolve(Terms, bindings, x) == cyclic
    end
  end

  describe "Bindings: unify_occurs_check" do
    test "a variable unifying with a compound containing itself fails, unlike plain unify/4" do
      x = {:var, make_ref()}
      cyclic = {:compound, :f, [x]}
      assert Bindings.unify_occurs_check(Terms, Bindings.new(), x, cyclic) == :fail
      assert {:ok, _} = Bindings.unify(Terms, Bindings.new(), x, cyclic)
    end

    test "the occurs-check still catches it through an already-bound variable, not just a literal one" do
      x = {:var, make_ref()}
      y = {:var, make_ref()}
      # y is already bound to x -- unifying x with f(y) is really x = f(x).
      {:ok, bindings} = Bindings.unify_occurs_check(Terms, Bindings.new(), y, x)
      assert Bindings.unify_occurs_check(Terms, bindings, x, {:compound, :f, [y]}) == :fail
    end

    test "ordinary (non-cyclic) unification still succeeds exactly like unify/4" do
      x = {:var, make_ref()}
      a = {:compound, :pair, [1, x]}
      b = {:compound, :pair, [1, 2]}
      assert {:ok, bindings} = Bindings.unify_occurs_check(Terms, Bindings.new(), a, b)
      assert Bindings.resolve(Terms, bindings, x) == 2
    end
  end
end
