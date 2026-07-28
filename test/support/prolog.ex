defmodule Prolog.Terms do
  @moduledoc """
  The worked example's own term representation: `{:var, ref}` for a
  logic variable (keyed by a fresh `reference/0` per variable, minted
  by whichever clause introduces it), `{:compound, functor, args}` for
  a compound term, anything else atomic. `Ichor.Backtrack.Bindings`
  never needs to know this shape exists -- it's entirely this module's
  own business, passed to `Bindings` explicitly as `term_module`.

  `reconstruct/2` (the optional half of `Ichor.Backtrack.Term`,
  `deconstruct/1`'s inverse) is implemented too, unlike the original
  Track 6 worked example's own version -- `Ichor.Toolkit.TermWalk`'s
  `rewrite/3` needs it to rebuild a compound after transforming its
  args, which `test/prolog/prolog.aether`'s own per-clause
  variable-freshening (`Prolog.Actions.freshen/1`) relies on. Purely
  additive: nothing about `unify/4`-only usage (this module's original
  purpose) changes.
  """

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

  @impl true
  def reconstruct(f, args), do: {:compound, f, args}
end

defmodule Prolog.DB do
  @moduledoc """
  The SLD-resolution loop itself -- `Ichor.Backtrack.Tree`/`Bindings`
  supply the search and unification substrate; everything about *what a
  clause is* and *how to try one* is this module's own code, exactly
  the boundary the roadmap drew for this track.

  A "predicate" is a plain list of clause functions, each `call_args ->
  goal`: called once per use (not once per definition), minting any
  fresh variables it needs internally (`{:var, make_ref()}`) so two
  uses of the same clause -- recursive or otherwise -- never
  accidentally share a variable. `solve_any/2` is `disjunction/2` folded
  over every clause, in declared order -- trying each clause is exactly
  Prolog's own left-to-right clause selection.
  """

  alias Ichor.Backtrack.{Bindings, Tree}
  alias Prolog.Terms

  @doc "A goal that unifies `t1` and `t2`, succeeding once (with the extended bindings) or not at all."
  def eq(t1, t2) do
    fn bindings ->
      case Bindings.unify(Terms, bindings, t1, t2) do
        {:ok, extended} -> Tree.unit().(extended)
        :fail -> Tree.fail().(bindings)
      end
    end
  end

  @doc "A goal that unifies every `{t1, t2}` pair in order, short-circuiting on the first failure."
  def unify_all(pairs) do
    Enum.reduce(pairs, Tree.unit(), fn {t1, t2}, acc_goal ->
      Tree.conjunction(acc_goal, eq(t1, t2))
    end)
  end

  @doc "Tries every clause (in order) against `call_args`, as a disjunction."
  def solve_any(clauses, call_args) do
    Enum.reduce(clauses, Tree.fail(), fn clause, acc_goal ->
      Tree.disjunction(acc_goal, clause.(call_args))
    end)
  end

  # ---- parent/2 -- ground facts only --------------------------------------

  def parent_clauses do
    [
      fn [x, y] -> unify_all([{x, :tom}, {y, :bob}]) end,
      fn [x, y] -> unify_all([{x, :tom}, {y, :liz}]) end,
      fn [x, y] -> unify_all([{x, :bob}, {y, :ann}]) end,
      fn [x, y] -> unify_all([{x, :bob}, {y, :pat}]) end
    ]
  end

  def parent(call_args), do: solve_any(parent_clauses(), call_args)

  # ---- grandparent(X, Z) :- parent(X, Y), parent(Y, Z). -------------------

  def grandparent_clauses do
    [
      fn [x, z] ->
        y = {:var, make_ref()}
        Tree.conjunction(parent([x, y]), parent([y, z]))
      end
    ]
  end

  def grandparent(call_args), do: solve_any(grandparent_clauses(), call_args)

  # ---- member(X, List) -- classic two-clause recursive predicate ---------
  #   member(X, [X|_]).
  #   member(X, [_|T]) :- member(X, T).
  # `list` here is a plain Elixir list of already-ground terms -- the
  # worked example's own simplification (a "real" Prolog list would be
  # `{:compound, :., [H, T]}` cons cells, which `Ichor.BacktrackTest`
  # already exercises directly; this predicate is about proving
  # recursion and laziness, not re-proving compound unification).

  def member_clauses([]), do: []

  def member_clauses([h | t]) do
    [
      fn [x] -> eq(x, h) end,
      fn [x] -> member([x, t]) end
    ]
  end

  def member([x, list]), do: solve_any(member_clauses(list), [x])
end
