defmodule Grammar.Native.LR do
  @moduledoc """
  The compile-time codegen backend for `@engine lr` grammars: builds the
  SLR(1) table via `Grammar.LRTable` once, at Elixir-compile-time (inside
  `use Ichor`'s macro expansion), and requires it be conflict-free --
  same requirement `Grammar.LR.compile/1` enforces at runtime, just
  checked once here instead of on every call.

  Since LR has no forking at all, everything compiles away into direct
  calls: one generated function per automaton state
  (`lr_state_<N>/4`), each a compiled `case` on the current lookahead
  terminal (`Grammar.LRTable.current_terminal/3`) deciding shift, reduce,
  or accept -- mirroring how `Grammar.Native.RuleCompiler` gives every
  PEG IR node its own function calling other nodes' functions directly,
  never an interpreted instruction loop.

  A shift's target state is always compile-time-known (fixed by the
  *current* state + the matched terminal), so it's a direct call to
  that state's own function -- zero lookup, the actual hot path (this
  runs once per input token). A reduce's `GOTO` target is *not*
  compile-time-known -- it depends on whichever state popping the
  production's RHS happens to expose, which varies with the parse's own
  history -- so every reduce goes through `lr_dispatch/5`, one compiled
  clause per state (a jump table, not a `Map.get`), and `lr_goto/2`, one
  compiled clause per `{nonterminal, state}` pair. Capture-building
  itself stays the shared, unchanged `Grammar.LRTable.Captures.build/3`
  (via `Grammar.LR.Stack.reduce/4`, `Macro.escape`'d one production per
  reduce clause) -- a small, data-driven fold over a handful of RHS
  positions, not the hot per-token loop this module actually compiles
  away.
  """

  alias Grammar.LRTable.Builder
  alias Grammar.Native.TokenizerCompiler
  alias Ichor.Toolkit.Codegen

  @doc "Generates the full quoted body (lexer + compiled LR parser + `parse/1,2` + `run/1,2`) for `grammar`, dispatching to `actions_module`."
  @spec generate(Aether.Grammar.t(), module()) :: Macro.t()
  def generate(%Aether.Grammar{engine: :lr} = grammar, actions_module) do
    case Builder.build(grammar) do
      {:error, errors} ->
        raise CompileError, description: Enum.map_join(errors, "\n", &Ichor.Error.format/1)

      {:ok, table} ->
        case Builder.conflicts(table) do
          [] ->
            do_generate(grammar, table, actions_module)

          conflicts ->
            details =
              Enum.map_join(conflicts, "\n", fn {state, symbol, actions} ->
                "  state #{state} on #{inspect(symbol)}: #{inspect(actions)}"
              end)

            raise CompileError,
              description:
                "Grammar.Native.LR requires a conflict-free table (use Grammar.Native.GLR for a grammar with genuine ambiguity):\n#{details}"
        end
    end
  end

  def generate(%Aether.Grammar{engine: engine}, _actions_module) do
    raise CompileError,
      description:
        "this grammar is tagged @engine #{engine} -- Grammar.Native.LR only compiles @engine lr grammars"
  end

  defp do_generate(grammar, table, actions_module) do
    {tokenizer_defs, tokenize_def} = TokenizerCompiler.generate(grammar)
    capture_shapes = Codegen.capture_shapes_ast(Grammar.VM.RuleCompiler.capture_shapes(grammar))
    root = grammar.root
    start_fn = state_fn_name(table.start_state)
    start_state = table.start_state

    state_defs = Enum.map(table.action, &generate_state(&1, table))
    dispatch_defs = generate_dispatch_defs(table)
    goto_defs = generate_goto_defs(table)

    # A `Grammar.IR.CustomLexeme` dependency needs a "re-lex and match a
    # rule R fresh" primitive that only exists against
    # `Grammar.Native.RuleCompiler`'s ordinary per-rule PEG functions --
    # spliced in here, unused by this module's own `parse`/`run`,
    # exactly mirroring how the interpreted `Grammar.LR` compiles a full
    # `Grammar.VM.RuleCompiler` program for this same reason alone. See
    # `Grammar.Native.TokenizerCompiler.has_customlexeme_deps?/1`.
    {parser_alias, peg_rule_defs} =
      if Grammar.Native.TokenizerCompiler.has_customlexeme_deps?(grammar) do
        {quote(do: alias(Grammar.Native.Runtime.Parser)),
         Grammar.Native.RuleCompiler.compile(grammar)}
      else
        {nil, []}
      end

    quote do
      # See `Grammar.Native.generate/2`'s own identical note: a
      # compile-time-known capture_shapes MapSet, plus a possibly-total
      # tokenizer depending on this grammar's own token patterns, both
      # known Dialyzer false-positive sources, not real bugs.
      @dialyzer [:no_opaque, :no_match]

      alias Grammar.LR.Stack
      alias Grammar.LRTable
      alias Grammar.Native.Runtime.Tokenizer
      alias Grammar.VM.Token
      unquote(parser_alias)

      unquote_splicing(tokenizer_defs)
      unquote(tokenize_def)
      unquote_splicing(peg_rule_defs)

      unquote_splicing(state_defs)
      unquote_splicing(dispatch_defs)
      unquote_splicing(goto_defs)

      @doc "Matches `input` against the grammar's root rule, requiring the entire (tokenized) input to be consumed. A bare recognizer -- no `Ichor.Actions` involved."
      @spec parse(String.t(), term()) ::
              {:ok, non_neg_integer(), map()} | {:error, Ichor.Error.t()}
      def parse(input, context \\ nil) do
        with {:ok, tokens} <- tokenize(input, context) do
          stream = List.to_tuple(tokens)
          initial_stack = [{unquote(start_state), 0, 0, nil}]
          unquote(start_fn)(initial_stack, stream, 0, context)
        end
      end

      @doc "Like `parse/1`, but runs the match through the compile-time-known Actions module, returning the grammar's actual evaluated result."
      @spec run(String.t(), Ichor.Actions.context()) ::
              {:ok, term()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
      def run(input, initial_context \\ nil) do
        with {:ok, _pos, raw_captures} <- parse(input, initial_context),
             {:ok, value, _context} <-
               Ichor.Actions.evaluate(
                 unquote(root),
                 raw_captures,
                 unquote(actions_module),
                 initial_context,
                 unquote(capture_shapes)
               ) do
          {:ok, value}
        end
      end
    end
  end

  defp state_fn_name(state), do: :"lr_state_#{state}"

  # `lr_state_N`'s own lookahead selector (`current_terminal/3`) is a
  # computed value, not a bare argument -- pattern-matched *function*
  # clauses can't dispatch on it, so this is the one place an actual
  # generated `case` (not a set of separate function clauses) is needed.
  defp generate_state({state, cells}, table) do
    fn_name = state_fn_name(state)
    stack = Macro.var(:stack, nil)
    stream = Macro.var(:stream, nil)
    pos = Macro.var(:pos, nil)

    # A state whose only actions are `:accept` never actually reads
    # `context` (only shift/reduce continuations propagate it) --
    # named `_context` there so that state's own generated function
    # doesn't trip an "unused variable" warning.
    context =
      if Enum.any?(cells, fn {_symbol, [action]} -> action != :accept end),
        do: Macro.var(:context, nil),
        else: Macro.var(:_context, nil)

    action_clauses =
      Enum.map(cells, fn {symbol, [action]} ->
        Codegen.clause(symbol, generate_action(action, table, stack, stream, pos, context))
      end)

    fallback =
      Codegen.clause(
        {:_, [], nil},
        quote(do: {:error, LRTable.unexpected_error(unquote(stream), unquote(pos))})
      )

    quote do
      defp unquote(fn_name)(unquote(stack), unquote(stream), unquote(pos), unquote(context)) do
        case LRTable.current_terminal(unquote(stream), unquote(pos), unquote(table.end_symbol)) do
          unquote(action_clauses ++ [fallback])
        end
      end
    end
  end

  defp generate_action(:accept, _table, stack, _stream, pos, _context) do
    quote do
      [{_state, _start, _end, captures} | _] = unquote(stack)
      {:ok, unquote(pos), captures}
    end
  end

  defp generate_action({:shift, target}, _table, stack, stream, pos, context) do
    target_fn = state_fn_name(target)

    quote do
      token = elem(unquote(stream), unquote(pos))

      unquote(target_fn)(
        Stack.push_token(unquote(stack), unquote(target), token, unquote(pos), unquote(pos) + 1),
        unquote(stream),
        unquote(pos) + 1,
        unquote(context)
      )
    end
  end

  defp generate_action({:reduce, prod_id}, table, stack, stream, pos, context) do
    production = Map.fetch!(table.productions, prod_id)
    escaped_production = Macro.escape(production)

    quote do
      {exposed_state, rest_stack, start_pos, end_pos, captures} =
        Stack.reduce(unquote(stack), unquote(escaped_production), unquote(stream), unquote(pos))

      target_state = lr_goto(unquote(production.lhs), exposed_state)
      new_stack = Stack.push_reduced(rest_stack, target_state, start_pos, end_pos, captures)
      lr_dispatch(target_state, new_stack, unquote(stream), unquote(pos), unquote(context))
    end
  end

  # `GOTO`'s target genuinely isn't compile-time-known (the state a
  # reduce's pop exposes depends on the parse's own history, not on
  # which production reduced), so every reduce goes through this one
  # compiled jump table instead of a direct call.
  defp generate_dispatch_defs(table) do
    stack = Macro.var(:stack, nil)
    stream = Macro.var(:stream, nil)
    pos = Macro.var(:pos, nil)
    context = Macro.var(:context, nil)

    Enum.map(Map.keys(table.action), fn state ->
      fn_name = state_fn_name(state)

      quote do
        defp lr_dispatch(
               unquote(state),
               unquote(stack),
               unquote(stream),
               unquote(pos),
               unquote(context)
             ),
             do: unquote(fn_name)(unquote(stack), unquote(stream), unquote(pos), unquote(context))
      end
    end)
  end

  defp generate_goto_defs(table) do
    for {state, gotos} <- table.goto, {nonterminal, target} <- gotos do
      quote do
        defp lr_goto(unquote(nonterminal), unquote(state)), do: unquote(target)
      end
    end
  end
end
