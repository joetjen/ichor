defmodule Grammar.GLR do
  @moduledoc """
  The interpreted graph-structured-stack backend: runs the same
  `Grammar.LRTable` SLR(1) table `Grammar.LR` does, but *accepts*
  conflicts instead of requiring their absence -- every action in a
  conflict cell is taken, forking the parse across a real
  `Grammar.GLR.GSS` (node-sharing, not independent per-branch stacks:
  two derivations that reach the same state at the same position
  merge, which is what keeps this from blowing up combinatorially on a
  grammar with only a handful of local conflicts). The GSS-driving loop
  itself lives in `Grammar.GLR.Runtime`, shared unchanged with
  `Grammar.Native.GLR` -- this module's own job is just building the
  table (recompiled on every call, the same "VM interpreted" convention
  `Grammar.VM` and `Grammar.LR` already follow) and wrapping its plain
  action/goto maps into the closures `Runtime.run/6` expects.

  This is *resolved* GLR, not full unresolved GLR: it never returns a
  parse forest. If more than one derivation survives all the way to
  accepting the whole input (genuine ambiguity, not just a table
  conflict that only one branch lived through), the winner is whichever
  one took the earliest-declared action at its *first* point of
  divergence from the others -- the same "first alternative, in file
  order, wins" convention plain PEG's ordered choice already uses (see
  `Grammar.LRTable.Automaton`'s `action_rank/1`, which sorts every
  conflict cell shift-then-reduce-by-production-id so this comparison
  means what it says). A grammar with no conflicts anywhere behaves
  identically to `Grammar.LR` on the same table.

  Only ever runs `@engine glr` grammars, same as `Grammar.LR` requires
  `@engine lr` and the PEG backends require `@engine peg` -- the tag is
  the grammar author's own declared choice of backend.
  """

  alias Grammar.GLR.Runtime
  alias Grammar.LRTable
  alias Grammar.LRTable.Builder
  alias Ichor.{Actions, Error}

  @type t :: %__MODULE__{table: LRTable.t(), capture_shapes: Actions.capture_shapes()}
  defstruct [:table, :capture_shapes]

  @doc "Builds `grammar`'s SLR(1) table -- conflicts are fine here, `Grammar.LR.compile/1` is what rejects them."
  @spec compile(Aether.Grammar.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def compile(%Aether.Grammar{} = grammar) do
    with {:ok, grammar} <- check_engine(grammar),
         {:ok, table} <- Builder.build(grammar) do
      {:ok,
       %__MODULE__{table: table, capture_shapes: Grammar.VM.RuleCompiler.capture_shapes(grammar)}}
    end
  end

  @doc "Matches `input` against `grammar`'s root, requiring the entire (tokenized) input to be consumed. A bare recognizer -- no `Ichor.Actions` involved."
  @spec parse(Aether.Grammar.t(), String.t(), term()) ::
          {:ok, non_neg_integer()} | {:error, Error.t() | [Error.t()]}
  def parse(%Aether.Grammar{} = grammar, input, context \\ nil) do
    with {:ok, glr} <- compile(grammar),
         {:ok, pos, _raw_captures, _locator} <- match(glr, grammar, input, context) do
      {:ok, pos}
    end
  end

  @doc "Like `parse/3`, but runs the match through `actions_module` starting from `initial_context`, returning the grammar's actual evaluated result."
  @spec run(Aether.Grammar.t(), String.t(), module(), Actions.context()) ::
          {:ok, term()} | {:error, Error.t() | [Error.t()]}
  def run(%Aether.Grammar{} = grammar, input, actions_module, initial_context \\ nil) do
    with {:ok, glr} <- compile(grammar),
         {:ok, _pos, raw_captures, locator} <- match(glr, grammar, input, initial_context),
         {:ok, value, _context} <-
           Actions.evaluate(
             grammar.root,
             raw_captures,
             actions_module,
             initial_context,
             glr.capture_shapes,
             locator: locator
           ) do
      {:ok, value}
    end
  end

  # ---- engine guard ---------------------------------------------------------

  @doc """
  Like `parse/3`, but returns the lossless tree of `input`
  (`Ichor.Syntax`): every byte of it, trivia and punctuation included,
  under every rule the grammar wrote that matched. Fails exactly as
  `parse/3` fails.
  """
  @spec parse_lossless(Aether.Grammar.t(), String.t(), term()) ::
          {:ok, Ichor.Syntax.Node.t()} | {:error, Error.t() | [Error.t()]}
  def parse_lossless(%Aether.Grammar{} = grammar, input, context \\ nil) do
    with {:ok, compiled} <- compile(grammar),
         {:ok, tree, _raw_captures, _locator} <-
           lossless_match(compiled, grammar, input, context) do
      {:ok, tree}
    end
  end

  @doc """
  Like `run/4`, returning the lossless tree of `input` beside the value:
  `{:ok, value, tree}`, `value` being exactly what `run/4` returns.
  """
  @spec run_lossless(Aether.Grammar.t(), String.t(), module(), Actions.context()) ::
          {:ok, term(), Ichor.Syntax.Node.t()} | {:error, Error.t() | [Error.t()]}
  def run_lossless(%Aether.Grammar{} = grammar, input, actions_module, initial_context \\ nil) do
    with {:ok, compiled} <- compile(grammar) do
      compiled
      |> lossless_match(grammar, input, initial_context)
      |> Grammar.LosslessShiftReduce.evaluated(
        grammar,
        actions_module,
        initial_context,
        compiled.capture_shapes
      )
    end
  end

  defp lossless_match(%__MODULE__{table: table}, grammar, input, context) do
    Grammar.LosslessShiftReduce.matched(
      grammar,
      table,
      input,
      context,
      fn action_fn, goto_fn, productions, start_state, end_symbol, stream ->
        Grammar.GLR.Runtime.run(
          action_fn,
          goto_fn,
          productions,
          start_state,
          end_symbol,
          stream,
          &Ichor.Syntax.Record.reduced/3
        )
      end
    )
  end

  defp check_engine(%Aether.Grammar{engine: :glr} = grammar), do: {:ok, grammar}

  defp check_engine(%Aether.Grammar{engine: engine}) do
    {:error,
     [
       Error.new(
         message:
           "this grammar is tagged @engine #{engine} -- Grammar.GLR only runs @engine glr grammars",
         stage: :parser
       )
     ]}
  end

  # ---- tokenize + delegate to the shared GSS runtime -------------------------

  defp match(%__MODULE__{table: table}, grammar, input, context) do
    with {:ok, tokens} <- tokenize(grammar, input, context) do
      stream = tokens |> Grammar.Source.trimmed(grammar.skip) |> List.to_tuple()
      action_fn = fn state, term -> table.action |> Map.get(state, %{}) |> Map.get(term, []) end
      goto_fn = fn state, nonterm -> table.goto |> Map.get(state, %{}) |> Map.get(nonterm) end

      action_fn
      |> Runtime.run(goto_fn, table.productions, table.start_state, table.end_symbol, stream)
      |> placed(stream, input)
    end
  end

  # The runtime builds "unexpected end of input" from the stream alone;
  # here, where the input is, it gets its line and column. A match gets
  # the locator its captures' recorded positions are counted in.
  defp placed({:error, error}, _stream, input), do: {:error, Grammar.Source.placed(error, input)}

  defp placed({:ok, pos, raw_captures}, stream, input),
    do: {:ok, pos, raw_captures, Grammar.Source.Locator.new(stream, input)}

  defp tokenize(grammar, input, context), do: Grammar.VM.tokenize(grammar, input, context)
end
