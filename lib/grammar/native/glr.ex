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

  alias Grammar.LRTable.Builder
  alias Grammar.Native.TokenizerCompiler
  alias Ichor.Toolkit.Codegen

  @doc """
  Generates the full quoted body (lexer + compiled GLR action/goto lookup
  + `parse/1,2` + `run/1,2`) for `grammar`, dispatching to
  `actions_module`.

  `lossless: true` adds `parse_lossless/1,2` and `run_lossless/1,2`
  (`Grammar.Native.Lossless`): the same run over the same compiled
  lookups, building with `Ichor.Syntax.Record.reduced/3`.
  """
  @spec generate(Aether.Grammar.t(), module(), keyword()) :: Macro.t()
  def generate(grammar, actions_module, opts \\ [])

  def generate(%Aether.Grammar{engine: :glr} = grammar, actions_module, opts) do
    case Builder.build(grammar) do
      {:error, errors} ->
        raise CompileError, description: Enum.map_join(errors, "\n", &Ichor.Error.format/1)

      {:ok, table} ->
        grammar
        |> do_generate(table, actions_module)
        |> with_lossless(grammar, table, actions_module, opts[:lossless])
    end
  end

  def generate(%Aether.Grammar{engine: engine}, _actions_module, _opts) do
    raise CompileError,
      description:
        "this grammar is tagged @engine #{engine} -- Grammar.Native.GLR only compiles @engine glr grammars"
  end

  defp do_generate(grammar, table, actions_module) do
    {tokenizer_defs, tokenize_def} = TokenizerCompiler.generate(grammar)
    capture_shapes = Codegen.capture_shapes_ast(Grammar.VM.RuleCompiler.capture_shapes(grammar))
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
      # See `Grammar.Native.generate/2`'s own identical note: a
      # compile-time-known capture_shapes MapSet, plus a possibly-total
      # tokenizer depending on this grammar's own token patterns, both
      # known Dialyzer false-positive sources, not real bugs.
      @dialyzer [:no_opaque, :no_match]

      alias Grammar.GLR.Runtime
      alias Grammar.Native.Runtime.Tokenizer
      alias Grammar.VM.Token
      unquote(parser_alias)

      unquote_splicing(tokenizer_defs)
      unquote(tokenize_def)
      unquote_splicing(peg_rule_defs)

      unquote_splicing(action_defs)
      unquote_splicing(goto_defs)

      @doc "Matches `input` against the grammar's root rule, requiring the entire (tokenized) input to be consumed. A bare recognizer -- no `Ichor.Actions` involved."
      @spec parse(String.t(), term()) ::
              {:ok, non_neg_integer(), Ichor.Capture.raw_captures()} | {:error, Ichor.Error.t()}
      def parse(input, context \\ nil) do
        with {:ok, pos, raw_captures, _locator} <- match(input, context) do
          {:ok, pos, Ichor.Capture.plain(raw_captures)}
        end
      end

      @doc "Matches `input` as `parse/2` does, keeping where each capture matched: `{:ok, pos, raw_captures, locator}` -- the captures raw, with the positions `Ichor.Capture.at/3` reads, and the `Grammar.Source.Locator` that turns them into spans -- or the error `parse/2` answers. For a caller that wants spans without actions; `run/2` evaluates the same match."
      @spec match(String.t(), term()) ::
              {:ok, non_neg_integer(), Ichor.Capture.raw_captures(), Grammar.Source.Locator.t()}
              | {:error, Ichor.Error.t()}
      def match(input, context \\ nil) do
        with {:ok, tokens} <- tokenize(input, context) do
          stream = tokens |> Grammar.Source.significant(unquote(grammar.skip)) |> List.to_tuple()

          case Runtime.run(
                 &glr_action/2,
                 &glr_goto/2,
                 unquote(productions),
                 unquote(start_state),
                 unquote(end_symbol),
                 stream
               ) do
            {:error, error} ->
              {:error, Grammar.Source.placed(error, input)}

            {:ok, pos, raw_captures} ->
              {:ok, pos, raw_captures, Grammar.Source.Locator.new(stream, input)}
          end
        end
      end

      @doc "Like `parse/1`, but runs the match through the compile-time-known Actions module, returning the grammar's actual evaluated result."
      @spec run(String.t(), Ichor.Actions.context()) ::
              {:ok, term()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
      def run(input, initial_context \\ nil) do
        with {:ok, _pos, raw_captures, locator} <- match(input, initial_context),
             {:ok, value, _context} <-
               Ichor.Actions.evaluate(
                 unquote(root),
                 raw_captures,
                 unquote(actions_module),
                 initial_context,
                 unquote(capture_shapes),
                 locator: locator
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
  defp with_lossless(body, _grammar, _table, _actions_module, lossless) when lossless != true,
    do: body

  defp with_lossless(body, grammar, table, actions_module, true) do
    run =
      quote do
        Grammar.GLR.Runtime.run(
          &glr_action/2,
          &glr_goto/2,
          unquote(Macro.escape(table.productions)),
          unquote(table.start_state),
          unquote(table.end_symbol),
          unquote(Grammar.Native.Lossless.stream_var()),
          &Ichor.Syntax.Record.reduced/3
        )
      end

    quote do
      unquote(body)
      unquote(Grammar.Native.Lossless.shift_reduce_defs(grammar, actions_module, run))
    end
  end

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
