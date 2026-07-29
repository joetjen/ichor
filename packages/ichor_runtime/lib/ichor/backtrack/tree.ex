defmodule Ichor.Backtrack.Tree do
  @moduledoc """
  The correctness-first `Ichor.Backtrack` engine: a solution is a plain
  thunk, `(-> :empty | {:solution, value, rest})` -- a manually-unfolded
  lazy list (a "search tree," hence the name), not backed by any
  process/agent or Elixir `Stream` machinery. Each combinator forces
  exactly one step of whatever it's combining, which is what makes
  `once/1` genuinely stop exploring rather than compute everything and
  discard all but the first result, and what makes an infinite Prolog
  recursion still yield its first solutions instead of hanging forever
  building a list.

  Kept intentionally simple over "fair" interleaving search (the way
  microKanren's own `mplus`/`bind` alternate between branches):
  `disjunction/2` exhausts its first argument before touching its
  second, depth-first, left-to-right -- exactly Prolog's own clause-order
  backtracking, not a design gap. A future WAM-grade engine implementing
  the same `Ichor.Backtrack` behaviour could still choose differently.
  """

  @behaviour Ichor.Backtrack

  @type t :: (-> :empty | {:solution, term(), t()})

  @impl true
  @spec unit() :: Ichor.Backtrack.goal()
  def unit, do: fn bindings -> of_one(bindings) end

  @impl true
  @spec fail() :: Ichor.Backtrack.goal()
  def fail, do: fn _bindings -> empty() end

  @impl true
  @spec disjunction(Ichor.Backtrack.goal(), Ichor.Backtrack.goal()) :: Ichor.Backtrack.goal()
  def disjunction(goal1, goal2), do: fn bindings -> concat(goal1.(bindings), goal2.(bindings)) end

  @impl true
  @spec conjunction(Ichor.Backtrack.goal(), Ichor.Backtrack.goal()) :: Ichor.Backtrack.goal()
  def conjunction(goal1, goal2), do: fn bindings -> flat_map(goal1.(bindings), goal2) end

  @impl true
  @spec once(Ichor.Backtrack.goal()) :: Ichor.Backtrack.goal()
  def once(goal), do: fn bindings -> take(goal.(bindings), 1) end

  @impl true
  @spec next(t()) :: :empty | {:solution, term(), t()}
  def next(solutions), do: solutions.()

  @doc "The empty solution sequence -- a goal that never succeeds reduces to this."
  @spec empty() :: t()
  def empty, do: fn -> :empty end

  @doc "A single solution followed by nothing else."
  @spec of_one(term()) :: t()
  def of_one(value), do: fn -> {:solution, value, empty()} end

  @doc "Every solution of `a`, then every solution of `b` -- `disjunction/2`'s own primitive."
  @spec concat(t(), t()) :: t()
  def concat(a, b) do
    fn ->
      case next(a) do
        :empty -> next(b)
        {:solution, value, rest} -> {:solution, value, concat(rest, b)}
      end
    end
  end

  @doc "Every solution of `solutions`, each fed through `fun` (itself producing a lazy sequence) and concatenated in order -- `conjunction/2`'s own primitive."
  @spec flat_map(t(), (term() -> t())) :: t()
  def flat_map(solutions, fun) do
    fn ->
      case next(solutions) do
        :empty -> :empty
        {:solution, value, rest} -> next(concat(fun.(value), flat_map(rest, fun)))
      end
    end
  end

  @doc "The first `n` solutions, computed lazily -- `once/1`'s own primitive (`n = 1`)."
  @spec take(t(), non_neg_integer()) :: t()
  def take(_solutions, 0), do: empty()

  def take(solutions, n) do
    fn ->
      case next(solutions) do
        :empty -> :empty
        {:solution, value, rest} -> {:solution, value, take(rest, n - 1)}
      end
    end
  end

  @doc "Eagerly pulls every solution into a plain list -- for tests/finite searches only; never call this on a search that might not terminate."
  @spec to_list(t()) :: [term()]
  def to_list(solutions) do
    case next(solutions) do
      :empty -> []
      {:solution, value, rest} -> [value | to_list(rest)]
    end
  end
end
