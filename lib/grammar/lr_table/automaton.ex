defmodule Grammar.LRTable.Automaton do
  @moduledoc """
  Canonical LR(0) item-set construction (closure/goto over
  `Grammar.LRTable.Desugar`'s flat production list), plus SLR(1)
  action/goto table construction on top of it.

  SLR(1), not full canonical LR(1) or LALR(1) -- a deliberate, simpler
  choice for a from-scratch v1 (no per-item lookahead propagation graph
  needed at all): a reduce action for a complete item `[A -> α ·]` is
  only offered on a lookahead terminal in `FOLLOW(A)`, computed once
  over the whole grammar rather than per state. This accepts every
  LR(0)-unambiguous grammar plus a useful chunk of real ones, at the
  cost of occasionally reporting a conflict a full LALR(1) table
  wouldn't -- `Grammar.GLR` forks on *any* multi-action cell regardless
  of why it's there, so a weaker table only means it forks a little more
  often, never that it parses incorrectly. Strengthening this to true
  LALR(1) later is a pure internal upgrade (same table shape, smarter
  lookahead), not a public API change.
  """

  alias Grammar.LRTable.Production

  @type item :: {production_id :: non_neg_integer(), dot :: non_neg_integer()}
  @type state_id :: non_neg_integer()
  @type action :: {:shift, state_id()} | {:reduce, production_id :: non_neg_integer()} | :accept

  @type t :: %__MODULE__{
          states: %{state_id() => MapSet.t(item())},
          transitions: %{{state_id(), Production.symbol()} => state_id()},
          start_state: state_id()
        }

  defstruct [:states, :transitions, :start_state]

  @doc "Builds the canonical LR(0) collection for `productions`, starting from `start_symbol`'s own production."
  @spec build([Production.t()], atom()) :: t()
  def build(productions, start_symbol) do
    by_id = Map.new(productions, &{&1.id, &1})
    by_lhs = Enum.group_by(productions, & &1.lhs)

    start_prod = Enum.find(productions, &(&1.lhs == start_symbol))
    start_items = closure(MapSet.new([{start_prod.id, 0}]), by_id, by_lhs)

    {states, transitions} =
      build_states(%{0 => start_items}, %{}, [0], by_id, by_lhs, 1)

    %__MODULE__{states: states, transitions: transitions, start_state: 0}
  end

  @doc """
  Builds the SLR(1) action table (`%{state => %{terminal => [action]}}` --
  more than one action in a cell is a conflict, left for the caller to
  decide whether that's fatal) and goto table
  (`%{state => %{nonterminal => state}}`, always single-valued -- goto
  transitions are deterministic by DFA construction, never a conflict).
  """
  @spec action_goto_tables(t(), [Production.t()], %{atom() => MapSet.t(atom())}, atom(), atom()) ::
          {action_table :: %{state_id() => %{atom() => [action()]}},
           goto_table :: %{state_id() => %{atom() => state_id()}}}
  def action_goto_tables(%__MODULE__{} = automaton, productions, follow, start_symbol, end_symbol) do
    by_id = Map.new(productions, &{&1.id, &1})

    action_table =
      Map.new(automaton.states, fn {state_id, items} ->
        {state_id,
         action_cell(state_id, items, by_id, automaton, follow, start_symbol, end_symbol)}
      end)

    goto_table =
      Enum.reduce(automaton.transitions, %{}, fn
        {{from, {:nonterminal, name}}, to}, acc ->
          Map.update(acc, from, %{name => to}, &Map.put(&1, name, to))

        {{_from, {:terminal, _name}}, _to}, acc ->
          acc
      end)

    {action_table, goto_table}
  end

  # ---- LR(0) construction ---------------------------------------------------

  defp closure(items, by_id, by_lhs) do
    fixpoint(items, fn items ->
      Enum.reduce(items, items, fn {prod_id, dot}, acc ->
        prod = Map.fetch!(by_id, prod_id)

        case Enum.at(prod.rhs, dot) do
          {:nonterminal, name} ->
            new_items = by_lhs |> Map.get(name, []) |> Enum.map(&{&1.id, 0})
            MapSet.union(acc, MapSet.new(new_items))

          _ ->
            acc
        end
      end)
    end)
  end

  defp fixpoint(set, step_fun) do
    next = step_fun.(set)
    if MapSet.equal?(next, set), do: set, else: fixpoint(next, step_fun)
  end

  defp goto(items, symbol, by_id, by_lhs) do
    moved =
      items
      |> Enum.filter(fn {prod_id, dot} ->
        Enum.at(Map.fetch!(by_id, prod_id).rhs, dot) == symbol
      end)
      |> Enum.map(fn {prod_id, dot} -> {prod_id, dot + 1} end)
      |> MapSet.new()

    if MapSet.size(moved) == 0, do: nil, else: closure(moved, by_id, by_lhs)
  end

  defp build_states(states, transitions, [], _by_id, _by_lhs, _next_id), do: {states, transitions}

  defp build_states(states, transitions, [state_id | rest], by_id, by_lhs, next_id) do
    items = Map.fetch!(states, state_id)

    symbols =
      items
      |> Enum.map(fn {pid, dot} -> Enum.at(Map.fetch!(by_id, pid).rhs, dot) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {states, transitions, worklist, next_id} =
      Enum.reduce(symbols, {states, transitions, rest, next_id}, fn symbol,
                                                                    {states, transitions,
                                                                     worklist, next_id} ->
        target_items = goto(items, symbol, by_id, by_lhs)

        case find_existing_state(states, target_items) do
          {:ok, existing_id} ->
            {states, Map.put(transitions, {state_id, symbol}, existing_id), worklist, next_id}

          :error ->
            states2 = Map.put(states, next_id, target_items)
            transitions2 = Map.put(transitions, {state_id, symbol}, next_id)
            {states2, transitions2, worklist ++ [next_id], next_id + 1}
        end
      end)

    build_states(states, transitions, worklist, by_id, by_lhs, next_id)
  end

  defp find_existing_state(states, target_items) do
    Enum.find_value(states, :error, fn {id, items} ->
      if items == target_items, do: {:ok, id}
    end)
  end

  # ---- SLR(1) action table ---------------------------------------------------

  defp action_cell(state_id, items, by_id, automaton, follow, start_symbol, end_symbol) do
    cell =
      Enum.reduce(items, %{}, fn {prod_id, dot}, acc ->
        prod = Map.fetch!(by_id, prod_id)

        case Enum.at(prod.rhs, dot) do
          nil ->
            reduce_actions(prod, follow, start_symbol, end_symbol, acc)

          {:terminal, name} ->
            case Map.get(automaton.transitions, {state_id, {:terminal, name}}) do
              nil -> acc
              target -> add_action(acc, name, {:shift, target})
            end

          {:nonterminal, _name} ->
            acc
        end
      end)

    # A conflict cell's actions are sorted canonically -- shift before
    # any reduce (the conventional yacc-style default when there's a
    # genuine choice), reduces themselves by production id ascending
    # (declaration order: `Grammar.LRTable.Desugar` numbers productions
    # in file order -- `Aether.Grammar.rule_order` across rules, a
    # `Choice`'s own alternative-list order within one rule) -- so
    # `Grammar.GLR`'s declared-order tie-break has a stable, meaningful
    # order to compare against, not whatever order this map happened to
    # get built in.
    Map.new(cell, fn {symbol, actions} -> {symbol, Enum.sort_by(actions, &action_rank/1)} end)
  end

  defp action_rank({:shift, _target}), do: {0, 0}
  defp action_rank({:reduce, prod_id}), do: {1, prod_id}
  defp action_rank(:accept), do: {0, 0}

  defp reduce_actions(%Production{lhs: start_symbol}, _follow, start_symbol, end_symbol, acc) do
    add_action(acc, end_symbol, :accept)
  end

  defp reduce_actions(prod, follow, _start_symbol, _end_symbol, acc) do
    lookaheads = Map.get(follow, prod.lhs, MapSet.new())

    Enum.reduce(lookaheads, acc, fn terminal, acc ->
      add_action(acc, terminal, {:reduce, prod.id})
    end)
  end

  defp add_action(cell_map, terminal, action) do
    Map.update(cell_map, terminal, [action], fn existing ->
      if action in existing, do: existing, else: existing ++ [action]
    end)
  end
end
