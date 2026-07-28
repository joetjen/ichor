defmodule Ichor.Toolkit.Fixpoint do
  @moduledoc """
  The generic "repeatedly recompute a value from itself until it stops
  changing" primitive -- extracted from a pattern that had already been
  hand-written three separate times in Ichor's own compiler internals
  before this existed: `Grammar.Analysis`'s private `fixpoint/3`
  (nullable-set and always-empty-set computation, both over a
  `MapSet.t(atom())` of rule/token names) and `Grammar.LRTable.Sets`'
  private `fixpoint/2`/`fixpoint_map/2` (FIRST/FOLLOW-set computation,
  one over a `MapSet`, one over a `Map`). None of those three needed
  anything MapSet- or Map-specific about the *iteration* itself -- only
  about what `step_fn` does with the value in between -- which is
  exactly what this generalizes: `step_fn` closes over whatever fixed
  data it needs (a grammar's own rule list, a graph, ...), this module
  never sees that data at all, only the value being iterated.

  A "fixpoint" here always means a *reached*, not merely a *theoretical*,
  one: `least/2` recurses until `step_fn` produces a value structurally
  equal (`==/2`) to its input, so `step_fn` must be monotone (each step
  only grows/refines the value, never oscillates) for this to actually
  terminate -- the same requirement every one of the three call sites
  above already relies on implicitly (each only ever adds names to a
  set, never removes any).
  """

  @doc """
  Applies `step_fn` to `initial`, then to its own result, and so on,
  until two successive values are equal -- returning that value.
  """
  @spec least(value, (value -> value)) :: value when value: term()
  def least(initial, step_fn) do
    next = step_fn.(initial)
    if next == initial, do: initial, else: least(next, step_fn)
  end
end
