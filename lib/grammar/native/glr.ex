defmodule Grammar.Native.GLR do
  @moduledoc """
  The compile-time codegen backend for `@engine glr` grammars: builds
  the SLR(1) table via `Grammar.LRTable` once, at Elixir-compile-time
  (conflicts are *expected* here, never rejected -- that's
  `Grammar.Native.LR`'s job), and compiles the action/goto lookup into
  per-state generated function clauses instead of the interpreted
  `Grammar.GLR`'s `Map.get`s.

  The graph-structured stack itself (`Grammar.GLR.GSS`: node merging,
  multi-path reduce enumeration) is inherently a runtime, input-driven
  data structure -- it can't compile away no matter which engine drives
  it, so `Grammar.GLR.Runtime.run/6` (already shared with the
  interpreted `Grammar.GLR`) is reused here completely unchanged, just
  handed `&glr_action/2`/`&glr_goto/2` -- compiled function references --
  in place of the closures-over-maps the interpreted path builds.
  """

  alias Grammar.LRTable
  alias Grammar.Native.TokenizerCompiler

  @doc "Generates the full quoted body (lexer + compiled GLR action/goto lookup + `parse/1,2` + `run/1,2`) for `grammar`, dispatching to `actions_module`."
  @spec generate(Aether.Grammar.t(), module()) :: Macro.t()
  def generate(%Aether.Grammar{engine: :glr} = grammar, actions_module) do
    case LRTable.build(grammar) do
      {:error, errors} ->
        raise CompileError, description: Enum.map_join(errors, "\n", &Ichor.Error.format/1)

      {:ok, table} ->
        do_generate(grammar, table, actions_module)
    end
  end

  def generate(%Aether.Grammar{engine: engine}, _actions_module) do
    raise CompileError,
      description:
        "this grammar is tagged @engine #{engine} -- Grammar.Native.GLR only compiles @engine glr grammars"
  end

  defp do_generate(grammar, table, actions_module) do
    {tokenizer_defs, tokenize_def} = TokenizerCompiler.generate(grammar)
    capture_shapes = Macro.escape(Grammar.VM.RuleCompiler.capture_shapes(grammar))
    productions = Macro.escape(table.productions)
    root = grammar.root
    start_state = table.start_state
    end_symbol = table.end_symbol

    action_defs = generate_action_defs(table)
    goto_defs = generate_goto_defs(table)

    # See `Grammar.Native.LR`'s own identical note: a `CustomLexeme`
    # dependency needs `Grammar.Native.RuleCompiler`'s ordinary per-rule
    # PEG functions, spliced in unused by this module's own `parse`/
    # `run` -- mirroring the interpreted `Grammar.GLR`'s own
    # `Grammar.VM.RuleCompiler` compile-for-this-reason-alone.
    {parser_alias, peg_rule_defs} =
      if Grammar.Native.TokenizerCompiler.has_customlexeme_deps?(grammar) do
        {quote(do: alias(Grammar.Native.Runtime.Parser)),
         Grammar.Native.RuleCompiler.compile(grammar)}
      else
        {nil, []}
      end

    quote do
      alias Grammar.GLR.Runtime
      alias Grammar.Native.Runtime.Tokenizer
      unquote(parser_alias)

      unquote_splicing(tokenizer_defs)
      unquote(tokenize_def)
      unquote_splicing(peg_rule_defs)

      unquote_splicing(action_defs)
      unquote_splicing(goto_defs)

      @doc "Matches `input` against the grammar's root rule, requiring the entire (tokenized) input to be consumed. A bare recognizer -- no `Ichor.Actions` involved."
      @spec parse(String.t(), term()) ::
              {:ok, non_neg_integer(), map()} | {:error, Ichor.Error.t()}
      def parse(input, context \\ nil) do
        with {:ok, tokens} <- tokenize(input, context) do
          stream = List.to_tuple(tokens)

          Runtime.run(
            &glr_action/2,
            &glr_goto/2,
            unquote(productions),
            unquote(start_state),
            unquote(end_symbol),
            stream
          )
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

  # One compiled clause per `{state, terminal}` cell that actually has
  # any action -- returning the *list* (possibly length > 1: GLR accepts
  # conflicts and forks over every action in it) -- plus a fallback
  # (`[]`, no action) for anything else, matching the interpreted path's
  # own `Map.get(..., [])` default.
  defp generate_action_defs(table) do
    clauses =
      for {state, cells} <- table.action, {symbol, actions} <- cells do
        quote do
          defp glr_action(unquote(state), unquote(symbol)), do: unquote(Macro.escape(actions))
        end
      end

    fallback =
      quote do
        defp glr_action(_state, _terminal), do: []
      end

    clauses ++ [fallback]
  end

  defp generate_goto_defs(table) do
    for {state, gotos} <- table.goto, {nonterminal, target} <- gotos do
      quote do
        defp glr_goto(unquote(state), unquote(nonterminal)), do: unquote(target)
      end
    end
  end
end
