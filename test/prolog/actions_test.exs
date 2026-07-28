defmodule Prolog.ActionsTest do
  @moduledoc """
  Proves `test/prolog/prolog.aether` end to end: real Prolog syntax
  (facts, rules with conjunction, `:- op(...).` directives genuinely
  mutating the operator table mid-file) parses into `Prolog.Terms`-shaped
  data, which then unifies via the *exact same* `Ichor.Backtrack`
  substrate `test/ichor/prolog_test.exs` already proved against
  hand-built terms -- closing the loop between Track 1 (`Grammar.IR.Custom`)
  and Track 6 (`Ichor.Backtrack`) with one real fixture.
  """

  use ExUnit.Case, async: true

  alias Ichor.Backtrack.Bindings
  alias Prolog.Terms

  defp grammar do
    source = File.read!(Path.join(__DIR__, "prolog.aether"))
    {:ok, grammar} = Aether.Parser.parse(source)
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  defp run_sequence(source) do
    Grammar.VM.run_sequence(grammar(), source, Prolog.Actions, Prolog.Actions.new_context())
  end

  describe "facts" do
    test "a ground compound term" do
      assert {:ok, [{:compound, :father, [:tom, :bob]}], _ctx} = run_sequence("father(tom, bob).")
    end

    test "several facts in one file, in order" do
      assert {:ok, facts, _ctx} =
               run_sequence("""
               father(tom, bob).
               father(bob, ann).
               """)

      assert facts == [
               {:compound, :father, [:tom, :bob]},
               {:compound, :father, [:bob, :ann]}
             ]
    end
  end

  describe "rules, conjunction, and variable scoping" do
    test "a rule's head and body share the same variable, freshened once per clause" do
      assert {:ok, [{:rule, head, body}], _ctx} =
               run_sequence("grandparent(X, Z) :- father(X, Y), father(Y, Z).")

      assert {:compound, :grandparent, [x1, z1]} = head
      assert [{:compound, :father, [x2, y1]}, {:compound, :father, [y2, z2]}] = body

      # The same *name* everywhere it appears in the clause -> the same ref.
      assert x1 == x2
      assert y1 == y2
      assert z1 == z2
      # Different names -> different refs.
      refute x1 == y1
      refute y1 == z1
    end

    test "the same variable name in a later clause is a different variable" do
      assert {:ok, [{:rule, {:compound, :p, [x1]}, _}, {:rule, {:compound, :q, [x2]}, _}], _ctx} =
               run_sequence("""
               p(X) :- father(X, bob).
               q(X) :- father(X, ann).
               """)

      refute x1 == x2
    end
  end

  describe "arithmetic via the default operator table, including prefix/infix sharing `-`" do
    test "* binds tighter than +, both looser than is" do
      assert {:ok, [{:rule, {:compound, :age, [n]}, body}], _ctx} =
               run_sequence("age(N) :- N is 2 + 3 * 4.")

      assert body == [{:compound, :is, [n, {:compound, :+, [2, {:compound, :*, [3, 4]}]}]}]
    end

    test "unary minus (prefix) binds tighter than binary minus (infix), same operator name" do
      assert {:ok, [{:rule, _head, body}], _ctx} = run_sequence("neg(N) :- N is -5 - 2.")
      assert [{:compound, :is, [_n, expr]}] = body
      assert expr == {:compound, :-, [{:compound, :-, [5]}, 2]}
    end
  end

  describe "op/3 directives genuinely extend the operator table mid-file" do
    test "an operator not in the default table can't be used before it's declared" do
      assert {:error, _} = run_sequence("weird(X) :- X is 2 ^ 3.")
    end

    test "after a directive declares it, later clauses can use it" do
      assert {:ok, results, _ctx} =
               run_sequence("""
               :- op(200, xfy, ^).
               weird(X) :- X is 2 ^ 3.
               """)

      assert [{:directive, {:compound, :op, [200, :xfy, :^]}}, {:rule, head, body}] = results
      assert {:compound, :weird, [x]} = head
      assert body == [{:compound, :is, [x, {:compound, :^, [2, 3]}]}]
    end

    test "the same source without the directive first behaves differently -- genuine runtime mutation, not a fixed table" do
      assert {:error, _} = run_sequence("weird(X) :- X is 2 ^ 3.")
      assert {:ok, _, _} = run_sequence(":- op(200, xfy, ^).\nweird(X) :- X is 2 ^ 3.")
    end
  end

  describe "closing the loop: a fact parsed from real syntax unifies via Ichor.Backtrack" do
    test "a parsed fact unifies with a hand-built query term" do
      {:ok, [fact], _ctx} = run_sequence("father(tom, bob).")

      var = {:var, make_ref()}
      query = {:compound, :father, [:tom, var]}
      assert {:ok, bindings} = Bindings.unify(Terms, Bindings.new(), fact, query)
      assert Bindings.resolve(Terms, bindings, var) == :bob
    end

    test "a parsed fact does not unify with a query for a different value" do
      {:ok, [fact], _ctx} = run_sequence("father(tom, bob).")
      query = {:compound, :father, [:tom, :ann]}
      assert Bindings.unify(Terms, Bindings.new(), fact, query) == :fail
    end
  end
end
