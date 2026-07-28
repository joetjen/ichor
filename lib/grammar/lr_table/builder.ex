defmodule Grammar.LRTable.Builder do
  @moduledoc """
  Builds an SLR(1) action/goto table (`Grammar.LRTable`, from
  `ichor_runtime`) from an `@engine lr`/`@engine glr` grammar -- shared
  by both `Grammar.LR` (which additionally requires the result be
  conflict-free) and `Grammar.GLR` (which accepts conflicts and forks
  over them at runtime).

  Pipeline: `Grammar.LRTable.Desugar` flattens `grammar.rules`' PEG-shaped
  IR into a flat CFG production list; `Grammar.LRTable.Sets` computes
  nullable/FIRST/FOLLOW over that list; `Grammar.LRTable.Automaton` builds
  the canonical LR(0) item-set collection and, on top of it, the SLR(1)
  action/goto tables. `build/1` never itself decides a conflict is
  fatal -- a cell with more than one action is simply present in
  `action` as a list of length > 1; it's each engine's own call whether
  that's acceptable.

  Dev-time-only: nothing here runs once a grammar's table has already
  been built (or generated code compiled from it) -- that's
  `Grammar.LRTable` itself, the one piece of this pipeline that ships in
  `ichor_runtime`.
  """

  alias Grammar.LRTable
  alias Grammar.LRTable.{Automaton, Desugar, Sets}

  @doc "Builds the SLR(1) table for `grammar`, or every unsupported-construct error found."
  @spec build(Aether.Grammar.t()) :: {:ok, LRTable.t()} | {:error, [Ichor.Error.t()]}
  def build(%Aether.Grammar{} = grammar) do
    with {:ok, productions} <- Desugar.run(grammar) do
      start_symbol = Desugar.start_symbol()
      end_symbol = Desugar.end_symbol()

      nullable = Sets.nullable(productions)
      first = Sets.first_sets(productions, nullable)
      follow = Sets.follow_sets(productions, nullable, first, start_symbol, end_symbol)

      automaton = Automaton.build(productions, start_symbol)

      {action, goto} =
        Automaton.action_goto_tables(automaton, productions, follow, start_symbol, end_symbol)

      table = %LRTable{
        productions: Map.new(productions, &{&1.id, &1}),
        action: action,
        goto: goto,
        start_state: automaton.start_state,
        start_symbol: start_symbol,
        end_symbol: end_symbol,
        root: grammar.root
      }

      {:ok, table}
    end
  end

  @doc "Every `{state, symbol, [actions]}` cell with more than one action -- a shift/reduce or reduce/reduce conflict."
  @spec conflicts(LRTable.t()) :: [{LRTable.state_id(), atom(), [LRTable.action()]}]
  def conflicts(%LRTable{action: action}) do
    for {state_id, cells} <- action,
        {symbol, actions} <- cells,
        length(actions) > 1 do
      {state_id, symbol, actions}
    end
    |> Enum.sort()
  end
end
