defmodule Grammar.LRTable do
  @moduledoc """
  The SLR(1) action/goto table shape itself, plus the two lookups every
  LR-family engine needs at match time -- interpreted (`Grammar.LR`,
  `Grammar.GLR.Runtime`) or compiled (generated `Grammar.Native.LR`/
  `.GLR` code) alike.

  Building a table from a grammar (`Grammar.LRTable.Builder.build/1`,
  which needs `Desugar`/`Sets`/`Automaton`) is a dev-time-only concern
  that stays in `ichor` proper -- this module holds only what a
  generated parser (or the interpreted engines) still calls once a
  table already exists.
  """

  alias Ichor.Error

  @type state_id :: non_neg_integer()
  @type action :: {:shift, state_id()} | {:reduce, production_id :: non_neg_integer()} | :accept

  @type t :: %__MODULE__{
          productions: %{non_neg_integer() => Grammar.LRTable.Production.t()},
          action: %{state_id() => %{atom() => [action()]}},
          goto: %{state_id() => %{atom() => state_id()}},
          start_state: state_id(),
          start_symbol: atom(),
          end_symbol: atom(),
          root: atom()
        }

  defstruct [:productions, :action, :goto, :start_state, :start_symbol, :end_symbol, :root]

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
