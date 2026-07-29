defmodule Grammar.VM do
  @moduledoc """
  The interpreted runtime backend: compiles an `Aether.Grammar` to
  bytecode and runs it against real input. No compile-time codegen step
  -- give it a grammar (from `Aether.Parser.parse/2` +
  `Grammar.Analysis.run/1`) whenever you have one, including one your
  own program only learns about at runtime (a user-supplied grammar, a
  plugin, a REPL's `:load`). See the tutorial's "Loading a grammar at
  runtime" section for a full worked example, and "Which path is right
  for you?" for how this compares to `use Ichor`/`Mix.Tasks.Ichor.Gen`.

  Two genuinely separate compiled programs are involved, matching
  Aether's own "every grammar compiles to a Lexer feeding a Parser, never
  a scannerless single pass" design: `Grammar.VM.CharCompiler` +
  `Grammar.VM.Tokenizer` turn the input string into a token stream (maximal
  munch over every declared token); `Grammar.VM.RuleCompiler` +
  `Grammar.VM.TokenInterpreter` then run the rules over *that* stream,
  never over raw characters -- building a raw capture tree as they go.

  `parse/3` is a bare recognizer (does `grammar.root` match `input`, full
  stop) with no `Ichor.Actions` involved. `run/4` is the actions-aware
  entry point: it matches, then hands the raw capture tree to
  `Ichor.Actions.evaluate/5` for a given Actions module and initial
  context, producing the grammar's actual result (a sandboxed program's
  value, a config map, ...) instead of just a yes/no. `run_sequence/4`
  is for a source that's a *sequence* of top-level matches against
  `grammar.root` rather than one single match spanning the whole input
  (loading a standard-library file one top-level form at a time, each one
  threading context into the next, is the motivating case) -- most
  grammars only ever need `run/4`.

  `context` reaches the *match* phase too now (`parse/3`'s third
  argument, `run/4`'s `initial_context`, `run_sequence/4`'s
  per-form-accumulated context for *rule*-level matching), read-only --
  the one thing that ever consults it there is a `Grammar.IR.Custom`
  `@native(...)` node, via `c:Ichor.CustomRule.match/4`, or a
  `Grammar.IR.CustomLexeme` one via `c:Ichor.CustomLexeme.scan/3`. Nothing
  else in `Grammar.VM.TokenInterpreter`/`Grammar.VM.Tokenizer` reads it; only
  `Ichor.Actions.evaluate/5` ever produces a *new* one.

  One real gap for `CustomLexeme` specifically: `run_sequence/4`
  tokenizes the *entire* input once, up front, with only
  `initial_context` -- unlike rule-level matching (re-run per top-level
  form, seeing that form's own accumulated context), a token that reads
  `context` can't see anything a *later* form's own evaluation produced.
  Fine for heredocs/string-interpolation (context there is either unused
  or fixed for the whole file); a hazard only for something
  `\\catcode`-like that needs re-tokenization as context evolves
  mid-sequence -- not something `run_sequence/4` supports today.
  """

  alias Grammar.IR
  alias Grammar.VM.{CharCompiler, RuleCompiler, TokenInterpreter, Tokenizer}
  alias Ichor.{Actions, Error}

  @doc """
  Compiles `grammar` and matches it against `input`, requiring the root
  rule to consume the entire (tokenized) input. Returns the number of
  tokens consumed on success -- a bare recognizer result, no
  `Ichor.Actions` involved.
  """
  @spec parse(Aether.Grammar.t(), String.t(), term()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def parse(%Aether.Grammar{} = grammar, input, context \\ nil) do
    with {:ok, pos, _raw_captures} <- match(grammar, input, context) do
      {:ok, pos}
    end
  end

  @doc """
  Like `parse/2`, but runs the match through `actions_module` (a
  `Ichor.Actions` implementation) starting from `initial_context`,
  returning the grammar's actual evaluated result.
  """
  @spec run(Aether.Grammar.t(), String.t(), module(), Actions.context()) ::
          {:ok, term()} | {:error, Error.t() | [Error.t()]}
  def run(%Aether.Grammar{} = grammar, input, actions_module, initial_context \\ nil) do
    with {:ok, _pos, raw_captures} <- match(grammar, input, initial_context),
         {:ok, value, _context} <-
           Actions.evaluate(
             grammar.root,
             raw_captures,
             actions_module,
             initial_context,
             RuleCompiler.capture_shapes(grammar)
           ) do
      {:ok, value}
    end
  end

  @doc """
  Evaluates `input` as a sequence of top-level matches against
  `grammar.root`, one after another (skipping only the grammar's own
  `@skip` trivia between them, the same as it would between any two
  ordinary tokens), threading context from each into the next. Returns
  every top-level value, in order, plus the final context.
  """
  @spec run_sequence(Aether.Grammar.t(), String.t(), module(), Actions.context()) ::
          {:ok, [term()], Actions.context()} | {:error, Error.t() | [Error.t()]}
  def run_sequence(%Aether.Grammar{} = grammar, input, actions_module, initial_context) do
    with {:ok, grammar} <- check_engine(grammar) do
      do_run_sequence_toplevel(grammar, input, actions_module, initial_context)
    end
  end

  defp do_run_sequence_toplevel(grammar, input, actions_module, initial_context) do
    capture_shapes = RuleCompiler.capture_shapes(grammar)
    {char_program, custom_lexemes} = CharCompiler.compile(grammar.tokens)
    rule_program = RuleCompiler.compile(grammar)
    entry = Map.fetch!(rule_program.entry_points, grammar.root)

    with {:ok, input} <- Grammar.Source.validate(input),
         {:ok, raw_tokens} <-
           Tokenizer.tokenize(
             char_program,
             custom_lexemes,
             lexable_token_order(grammar),
             rule_program,
             initial_context,
             input
           ),
         {:ok, tokens} <- Grammar.Lexer.reclassify(raw_tokens, grammar.refiners) do
      do_run_sequence(
        rule_program,
        entry,
        List.to_tuple(tokens),
        0,
        grammar,
        capture_shapes,
        actions_module,
        initial_context,
        []
      )
    end
  end

  defp do_run_sequence(
         rule_program,
         entry,
         stream,
         pos,
         grammar,
         shapes,
         actions_module,
         ctx,
         acc
       ) do
    pos = skip_leading_trivia(stream, pos, grammar.skip)

    do_run_sequence_at(
      rule_program,
      entry,
      stream,
      pos,
      grammar,
      shapes,
      actions_module,
      ctx,
      acc
    )
  end

  # Between two top-level matches there's no enclosing sequence for
  # `Aether.Parser`'s own skip-splicing to have spliced anything into --
  # a leading `@skip` token here is genuinely
  # unconsumed, structural leftover from the *previous* top-level match,
  # not something `grammar.root` itself would ever expect to see.
  defp skip_leading_trivia(_stream, pos, nil), do: pos

  defp skip_leading_trivia(stream, pos, skip_name) do
    if pos < tuple_size(stream) and elem(stream, pos).name == skip_name do
      skip_leading_trivia(stream, pos + 1, skip_name)
    else
      pos
    end
  end

  defp do_run_sequence_at(_rp, _entry, stream, pos, _grammar, _shapes, _am, ctx, acc)
       when pos >= tuple_size(stream) do
    {:ok, Enum.reverse(acc), ctx}
  end

  defp do_run_sequence_at(
         rule_program,
         entry,
         stream,
         pos,
         grammar,
         shapes,
         actions_module,
         ctx,
         acc
       ) do
    case TokenInterpreter.run_from(rule_program.instructions, entry, stream, pos, ctx) do
      {:ok, new_pos, raw_captures} ->
        case Actions.evaluate(grammar.root, raw_captures, actions_module, ctx, shapes) do
          {:ok, value, new_ctx} ->
            do_run_sequence(
              rule_program,
              entry,
              stream,
              new_pos,
              grammar,
              shapes,
              actions_module,
              new_ctx,
              [
                value | acc
              ]
            )

          {:error, _} = err ->
            err
        end

      :fail ->
        {:error,
         Error.new(message: "input does not match #{inspect(grammar.root)}", stage: :parser)}
    end
  end

  defp match(%Aether.Grammar{} = grammar, input, context) do
    with {:ok, grammar} <- check_engine(grammar) do
      do_match(grammar, input, context)
    end
  end

  defp do_match(grammar, input, context) do
    {char_program, custom_lexemes} = CharCompiler.compile(grammar.tokens)
    rule_program = RuleCompiler.compile(grammar)

    with {:ok, input} <- Grammar.Source.validate(input),
         {:ok, raw_tokens} <-
           Tokenizer.tokenize(
             char_program,
             custom_lexemes,
             lexable_token_order(grammar),
             rule_program,
             context,
             input
           ),
         {:ok, tokens} <- Grammar.Lexer.reclassify(raw_tokens, grammar.refiners) do
      stream = List.to_tuple(tokens)
      entry = Map.fetch!(rule_program.entry_points, grammar.root)

      case TokenInterpreter.run(rule_program.instructions, entry, stream, context) do
        {:ok, pos, raw_captures} when pos == tuple_size(stream) ->
          {:ok, pos, raw_captures}

        {:ok, pos, _raw_captures} ->
          {:error, unexpected_token_error(stream, pos, input)}

        :fail ->
          {:error,
           Error.new(
             message: "input does not match #{inspect(grammar.root)}",
             stage: :parser,
             source: input
           )}
      end
    end
  end

  # Maximal munch only needs to consider tokens the grammar can actually
  # see arrive in the stream: ones a *rule* references directly, plus the
  # `@skip` token. A token used only as a sub-component of another
  # token's own definition (e.g. `SPACE` inside `TRIVIA := (SPACE |
  # COMMENT)*`, a common skip-token pattern) never needs to win the
  # top-level race on its own -- and if it's allowed to compete anyway, it
  # sometimes *does* win it (same span, tied length, declared first),
  # leaving `:SPACE` tokens in the stream where the parser's
  # `@skip`-driven splicing specifically expects `:TRIVIA`. Excluding pure
  # helper tokens from the top-level race is what maximal munch actually
  # needs: "the lexer" competing over the tokens a grammar's rules can
  # reference, not literally every token declared anywhere.
  #
  # Public (not just used by this module's own `match/2`) because
  # `Grammar.Native`'s generated lexer needs the exact same restricted
  # candidate set -- maximal munch means the same thing on both backends,
  # so this determination can't be allowed to drift between them.
  @doc false
  @spec lexable_token_order(Aether.Grammar.t()) :: [atom()]
  def lexable_token_order(grammar) do
    token_names = MapSet.new(Map.keys(grammar.tokens))

    referenced =
      Enum.reduce(grammar.rules, MapSet.new(), fn {_name, ir}, acc ->
        collect_token_refs(ir, token_names, acc)
      end)

    referenced = if grammar.skip, do: MapSet.put(referenced, grammar.skip), else: referenced

    Enum.filter(grammar.token_order, &MapSet.member?(referenced, &1))
  end

  defp collect_token_refs(%IR.RuleRef{name: name}, token_names, acc) do
    if MapSet.member?(token_names, name), do: MapSet.put(acc, name), else: acc
  end

  defp collect_token_refs(ir, token_names, acc) do
    Enum.reduce(IR.children(ir), acc, &collect_token_refs(&1, token_names, &2))
  end

  # A grammar tagged `@engine lr`/`@engine glr` never had its left
  # recursion rewritten (`Grammar.Analysis` only does that for `:peg` --
  # see `Aether.Grammar`'s own moduledoc); running it through recursive
  # descent would infinite-loop instead of failing cleanly, so this is
  # checked up front rather than left to surface as a hang.
  defp check_engine(%Aether.Grammar{engine: :peg} = grammar), do: {:ok, grammar}

  defp check_engine(%Aether.Grammar{engine: engine}) do
    {:error,
     Error.new(
       message:
         "this grammar is tagged @engine #{engine} -- Grammar.VM only runs @engine peg grammars; use Grammar.LR/Grammar.GLR instead",
       stage: :parser
     )}
  end

  defp unexpected_token_error(stream, pos, input) do
    %Grammar.VM.Token{text: text, line: line, column: col} = elem(stream, pos)

    Error.new(
      message: "unexpected #{inspect(text)} -- did not expect more input here",
      stage: :parser,
      line: line,
      column: col,
      source: input
    )
  end
end
