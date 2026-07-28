defmodule Grammar.LRTable.Sets do
  @moduledoc """
  Standard textbook nullable/FIRST/FOLLOW fixpoint algorithms, over
  `Grammar.LRTable.Desugar`'s flat CFG production list rather than the
  original PEG IR -- recomputed fresh (not reusing `Grammar.Analysis`'s
  own `compute_nullable/1`) since the augmented nonterminal set here
  includes every helper nonterminal a `Star`/`Plus`/`Opt`/`Rep`/group
  desugared into, which `Grammar.Analysis` never sees.
  """

  alias Grammar.LRTable.Production
  alias Ichor.Toolkit.Fixpoint

  @doc "Every nonterminal that can derive the empty string."
  @spec nullable([Production.t()]) :: MapSet.t(atom())
  def nullable(productions) do
    Fixpoint.least(MapSet.new(), fn nullable_set ->
      Enum.reduce(productions, nullable_set, fn %Production{lhs: lhs, rhs: rhs}, acc ->
        if Enum.all?(rhs, &symbol_nullable?(&1, nullable_set)) do
          MapSet.put(acc, lhs)
        else
          acc
        end
      end)
    end)
  end

  @doc "FIRST(N) for every nonterminal N -- FIRST of a terminal is just itself, never stored here."
  @spec first_sets([Production.t()], MapSet.t(atom())) :: %{atom() => MapSet.t(atom())}
  def first_sets(productions, nullable_set) do
    initial = productions |> Enum.map(& &1.lhs) |> Enum.uniq() |> Map.new(&{&1, MapSet.new()})

    Fixpoint.least(initial, fn first ->
      Enum.reduce(productions, first, fn %Production{lhs: lhs, rhs: rhs}, acc ->
        contributed = first_of_sequence(rhs, acc, nullable_set)
        Map.update!(acc, lhs, &MapSet.union(&1, contributed))
      end)
    end)
  end

  @doc """
  FOLLOW(N) for every nonterminal N. `start_symbol`'s FOLLOW seeds with
  `end_symbol` -- the synthetic end-of-input terminal, never a real token.
  """
  @spec follow_sets(
          [Production.t()],
          MapSet.t(atom()),
          %{atom() => MapSet.t(atom())},
          atom(),
          atom()
        ) ::
          %{atom() => MapSet.t(atom())}
  def follow_sets(productions, nullable_set, first, start_symbol, end_symbol) do
    initial =
      productions
      |> Enum.map(& &1.lhs)
      |> Enum.uniq()
      |> Map.new(&{&1, MapSet.new()})
      |> Map.update!(start_symbol, &MapSet.put(&1, end_symbol))

    Fixpoint.least(initial, fn follow ->
      Enum.reduce(productions, follow, fn %Production{lhs: lhs, rhs: rhs}, acc ->
        update_follow_for_rhs(rhs, lhs, acc, follow, first, nullable_set)
      end)
    end)
  end

  # ---- shared helpers ------------------------------------------------------

  @doc false
  @spec first_of_sequence([Production.symbol()], %{atom() => MapSet.t(atom())}, MapSet.t(atom())) ::
          MapSet.t(atom())
  def first_of_sequence([], _first, _nullable), do: MapSet.new()
  def first_of_sequence([{:terminal, name} | _rest], _first, _nullable), do: MapSet.new([name])

  def first_of_sequence([{:nonterminal, name} | rest], first, nullable) do
    this_first = Map.get(first, name, MapSet.new())

    if MapSet.member?(nullable, name) do
      MapSet.union(this_first, first_of_sequence(rest, first, nullable))
    else
      this_first
    end
  end

  defp symbol_nullable?({:terminal, _name}, _nullable_set), do: false

  defp symbol_nullable?({:nonterminal, name}, nullable_set),
    do: MapSet.member?(nullable_set, name)

  defp update_follow_for_rhs(rhs, lhs, acc, follow_before, first, nullable) do
    rhs
    |> Enum.with_index()
    |> Enum.reduce(acc, fn
      {{:nonterminal, name}, idx}, acc ->
        beta = Enum.drop(rhs, idx + 1)
        first_beta = first_of_sequence(beta, first, nullable)
        acc = Map.update!(acc, name, &MapSet.union(&1, first_beta))

        if beta == [] or Enum.all?(beta, &symbol_nullable?(&1, nullable)) do
          Map.update!(acc, name, &MapSet.union(&1, Map.get(follow_before, lhs, MapSet.new())))
        else
          acc
        end

      {{:terminal, _name}, _idx}, acc ->
        acc
    end)
  end
end
