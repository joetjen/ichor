defmodule Ichor.Backtrack do
  @moduledoc """
  The behaviour a lazy backtracking search engine implements --
  `Ichor.Backtrack.Tree` (Stream-backed, correctness-first) is the only
  one today; a future WAM-grade engine would implement the same
  contract, letting whatever's built on top (a Prolog-style
  SLD-resolution loop, say) swap engines without changing.

  A `goal` is a function from the current `bindings` to a lazy sequence
  of `solutions` -- one per way that goal can succeed, in order. Nothing
  here knows what a "binding" or a "clause database" is; that's
  `Ichor.Backtrack.Bindings`/`Ichor.Backtrack.Term`'s job (the
  unification substrate) and the caller's own SLD-resolution code
  respectively. This module supplies only the *search* structure:

    - `unit/0` -- succeeds exactly once, with the bindings unchanged
      (Prolog's `true`).
    - `fail/0` -- never succeeds (Prolog's `fail`).
    - `disjunction/2` -- every solution of the first goal, then every
      solution of the second, both starting from the same bindings
      (Prolog's `;` / trying clauses in declared order).
    - `conjunction/2` -- every solution of the first goal, each one
      threaded into the second as its own starting bindings, depth-first
      (Prolog's `,` / sequencing subgoals).
    - `once/1` -- at most the first solution of a goal, computed lazily
      (Prolog's cut/`once/1`) -- the rest of the search tree is never
      even explored, not just discarded after the fact.

  `solutions` is opaque and pulled incrementally via `next/1` --
  `{:solution, value, rest}` for one result plus the remaining lazy
  sequence, or `:empty` -- so an infinite or very large search space
  never needs to be materialized to get its first few answers.
  """

  @typedoc "Whatever a concrete engine's own solutions representation is -- opaque outside that engine."
  @type solutions :: term()

  @typedoc "A `bindings -> solutions` function -- succeeding produces bindings, not a bare boolean, since SLD-resolution needs to thread them into whatever comes next."
  @type goal :: (bindings :: term() -> solutions())

  @callback unit() :: goal()
  @callback fail() :: goal()
  @callback disjunction(goal(), goal()) :: goal()
  @callback conjunction(goal(), goal()) :: goal()
  @callback once(goal()) :: goal()
  @callback next(solutions()) :: :empty | {:solution, term(), solutions()}
end
