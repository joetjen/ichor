defmodule Grammar.LRTable do
  @moduledoc """
  Builds an SLR(1) action/goto table from an `@engine lr`/`@engine glr`
  grammar -- shared by both `Grammar.LR` (which additionally requires the
  result be conflict-free) and `Grammar.GLR` (which accepts conflicts and
  forks over them at runtime).

  Pipeline: `Grammar.LRTable.Desugar` flattens `grammar.rules`' PEG-shaped
  IR into a flat CFG production list; `Grammar.LRTable.Sets` computes
  nullable/FIRST/FOLLOW over that list; `Grammar.LRTable.Automaton` builds
  the canonical LR(0) item-set collection and, on top of it, the SLR(1)
  action/goto tables. `build/1` never itself decides a conflict is
  fatal -- a cell with more than one action is simply present in
  `action` as a list of length > 1; it's each engine's own call whether
  that's acceptable.
  """

  alias Grammar.LRTable.{Automaton, Desugar, Production, Sets}
  alias Ichor.Error

  @type state_id :: Automaton.state_id()

  @type t :: %__MODULE__{
          productions: %{non_neg_integer() => Production.t()},
          action: %{state_id() => %{atom() => [Automaton.action()]}},
          goto: %{state_id() => %{atom() => state_id()}},
          start_state: state_id(),
          start_symbol: atom(),
          end_symbol: atom(),
          root: atom()
        }

  defstruct [:productions, :action, :goto, :start_state, :start_symbol, :end_symbol, :root]

  @doc "Builds the SLR(1) table for `grammar`, or every unsupported-construct error found."
  @spec build(Aether.Grammar.t()) :: {:ok, t()} | {:error, [Error.t()]}
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

      table = %__MODULE__{
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
  @spec conflicts(t()) :: [{state_id(), atom(), [Automaton.action()]}]
  def conflicts(%__MODULE__{action: action}) do
    for {state_id, cells} <- action,
        {symbol, actions} <- cells,
        length(actions) > 1 do
      {state_id, symbol, actions}
    end
    |> Enum.sort()
  end

  @doc """
  The current lookahead terminal name at `pos` in `stream`, or
  `end_symbol` once input is exhausted -- shared by every LR-family
  engine (`Grammar.LR`, `Grammar.GLR.Runtime`, and generated
  `Grammar.Native.LR`/`.GLR` code alike), interpreted or compiled.
  """
  @spec current_terminal(tuple(), non_neg_integer(), atom()) :: atom()
  def current_terminal(stream, pos, end_symbol) do
    if pos >= tuple_size(stream), do: end_symbol, else: elem(stream, pos).name
  end

  @doc "The shared \"no action applies here\" parse error, naming the offending token (or end of input)."
  @spec unexpected_error(tuple(), non_neg_integer()) :: Error.t()
  def unexpected_error(stream, pos) when pos >= tuple_size(stream) do
    Error.new(message: "unexpected end of input", stage: :parser)
  end

  def unexpected_error(stream, pos) do
    %Grammar.VM.Token{text: text, line: line, column: col} = elem(stream, pos)

    Error.new(
      message: "unexpected #{inspect(text)} -- did not expect more input here",
      stage: :parser,
      line: line,
      column: col
    )
  end
end
