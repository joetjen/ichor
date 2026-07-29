defmodule Grammar.LR do
  @moduledoc """
  The deterministic bottom-up backend: builds an SLR(1) table via
  `Grammar.LRTable` and requires it be conflict-free -- a real conflict
  is a compile-time error here (`compile/1`), never something forked
  through (that's what `Grammar.GLR` is for). No graph-structured-stack
  bookkeeping at all: an ordinary shift-reduce loop over a single stack.

  Only ever runs `@engine lr` grammars -- same reasoning `Grammar.VM`/
  `Grammar.Native` reject anything but `@engine peg`: the tag is a
  grammar author's own declared choice of backend, and running a
  grammar through the wrong one is a bug worth catching immediately
  rather than silently doing something unintended.

  Builds the exact same raw-capture shape `Ichor.Actions` expects
  (`{:token,...}`/`{:rule,...}`/`{:text,...}`) at every reduce, using
  `Grammar.LRTable.Production.t()`'s own `captures` plan -- see its
  moduledoc for what each capture kind means. Reuses
  `Grammar.VM.RuleCompiler.capture_shapes/1` unchanged (a pure static
  pass over `grammar.rules`' IR, unaffected by how a table-driven engine
  parses it) so `Ichor.Actions.evaluate/5` needs no changes at all to
  work with this backend.
  """

  alias Grammar.LR.Stack
  alias Grammar.LRTable
  alias Grammar.LRTable.Builder
  alias Ichor.{Actions, Error}

  @type t :: %__MODULE__{table: LRTable.t(), capture_shapes: Actions.capture_shapes()}
  defstruct [:table, :capture_shapes]

  @doc "Builds `grammar`'s SLR(1) table and requires it be conflict-free, or reports every conflict found."
  @spec compile(Aether.Grammar.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def compile(%Aether.Grammar{} = grammar) do
    with {:ok, grammar} <- check_engine(grammar),
         {:ok, table} <- Builder.build(grammar) do
      case Builder.conflicts(table) do
        [] ->
          {:ok,
           %__MODULE__{
             table: table,
             capture_shapes: Grammar.VM.RuleCompiler.capture_shapes(grammar)
           }}

        conflicts ->
          {:error, Enum.map(conflicts, &conflict_error/1)}
      end
    end
  end

  @doc "Matches `input` against `grammar`'s root, requiring the entire (tokenized) input to be consumed. A bare recognizer -- no `Ichor.Actions` involved."
  @spec parse(Aether.Grammar.t(), String.t(), term()) ::
          {:ok, non_neg_integer()} | {:error, Error.t() | [Error.t()]}
  def parse(%Aether.Grammar{} = grammar, input, context \\ nil) do
    with {:ok, lr} <- compile(grammar),
         {:ok, pos, _raw_captures} <- match(lr, grammar, input, context) do
      {:ok, pos}
    end
  end

  @doc "Like `parse/3`, but runs the match through `actions_module` starting from `initial_context`, returning the grammar's actual evaluated result."
  @spec run(Aether.Grammar.t(), String.t(), module(), Actions.context()) ::
          {:ok, term()} | {:error, Error.t() | [Error.t()]}
  def run(%Aether.Grammar{} = grammar, input, actions_module, initial_context \\ nil) do
    with {:ok, lr} <- compile(grammar),
         {:ok, _pos, raw_captures} <- match(lr, grammar, input, initial_context),
         {:ok, value, _context} <-
           Actions.evaluate(
             grammar.root,
             raw_captures,
             actions_module,
             initial_context,
             lr.capture_shapes
           ) do
      {:ok, value}
    end
  end

  # ---- engine guard ---------------------------------------------------------

  defp check_engine(%Aether.Grammar{engine: :lr} = grammar), do: {:ok, grammar}

  defp check_engine(%Aether.Grammar{engine: engine}) do
    {:error,
     [
       Error.new(
         message:
           "this grammar is tagged @engine #{engine} -- Grammar.LR only runs @engine lr grammars",
         stage: :parser
       )
     ]}
  end

  defp conflict_error({state, symbol, actions}) do
    Error.new(
      message:
        "conflict in state #{state} on #{inspect(symbol)}: #{inspect(actions)} -- Grammar.LR requires a conflict-free table (use Grammar.GLR for a grammar with genuine ambiguity)",
      stage: :analysis
    )
  end

  # ---- tokenize + shift-reduce ------------------------------------------------

  defp match(%__MODULE__{table: table}, grammar, input, context) do
    with {:ok, tokens} <- tokenize(grammar, input, context) do
      run_shift_reduce(table, List.to_tuple(tokens))
    end
  end

  defp tokenize(grammar, input, context) do
    {char_program, custom_lexemes} = Grammar.VM.CharCompiler.compile(grammar.tokens)
    rule_program = Grammar.VM.RuleCompiler.compile(grammar)
    lexable = Grammar.VM.lexable_token_order(grammar)

    with {:ok, input} <- Grammar.Source.validate(input),
         {:ok, raw_tokens} <-
           Grammar.VM.Tokenizer.tokenize(
             char_program,
             custom_lexemes,
             lexable,
             rule_program,
             context,
             input
           ) do
      Grammar.Lexer.reclassify(raw_tokens, grammar.refiners)
    end
  end

  defp run_shift_reduce(table, stream) do
    step(table, stream, 0, [{table.start_state, 0, 0, nil}])
  end

  defp step(table, stream, pos, [{state, _, _, _} | _] = stack) do
    lookahead = LRTable.current_terminal(stream, pos, table.end_symbol)

    case table.action |> Map.get(state, %{}) |> Map.get(lookahead) do
      nil ->
        {:error, LRTable.unexpected_error(stream, pos)}

      [:accept] ->
        [{_state, _start, _end, captures} | _] = stack
        {:ok, pos, captures}

      [{:shift, target}] ->
        token = elem(stream, pos)
        step(table, stream, pos + 1, Stack.push_token(stack, target, token, pos, pos + 1))

      [{:reduce, prod_id}] ->
        step(table, stream, pos, do_reduce(table, stream, prod_id, stack, pos))
    end
  end

  defp do_reduce(table, stream, prod_id, stack, pos) do
    production = Map.fetch!(table.productions, prod_id)

    {exposed_state, rest_stack, start_pos, end_pos, captures} =
      Stack.reduce(stack, production, stream, pos)

    target_state = table.goto |> Map.fetch!(exposed_state) |> Map.fetch!(production.lhs)
    Stack.push_reduced(rest_stack, target_state, start_pos, end_pos, captures)
  end
end
