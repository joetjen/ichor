defmodule Grammar.Native do
  @moduledoc """
  The compile-time codegen backend: turns a validated `%Aether.Grammar{}`
  into quoted Elixir function definitions -- the same two-stage Lexer ->
  Parser split `Grammar.VM` compiles to bytecode for, but here as direct
  function calls a `use Ichor, grammar:, actions:` caller splices
  straight into its own module (via `Ichor`'s `__using__` macro),
  skipping bytecode interpretation entirely.

  Dispatches to `actions_module` via a compile-time-known module
  reference: `Ichor.Actions.evaluate/5` is called directly with that
  module baked in as a literal, never looked up dynamically -- reusing
  `Ichor.Actions`'s own default-fallback and capture-shape-normalization
  logic rather than re-deriving it, since the actual speed win is in the
  match phase (a compiled lexer/parser instead of an interpreted
  bytecode loop), not in re-implementing evaluation.
  """

  alias Grammar.Native.RuleCompiler
  alias Grammar.Native.TokenizerCompiler
  alias Grammar.VM.RuleCompiler, as: VMRuleCompiler
  alias Ichor.Toolkit.Codegen

  @doc """
  Generates the full quoted body (lexer + parser + `parse/1` + `run/1,2`)
  for `grammar`, dispatching to `actions_module`.

  `lossless: true` adds `parse_lossless/1,2` and `run_lossless/1,2`
  (`Ichor.Syntax`), over a second set of rule functions of their own.
  """
  @spec generate(Aether.Grammar.t(), module(), keyword()) :: Macro.t()
  def generate(grammar, actions_module, opts \\ [])

  def generate(%Aether.Grammar{engine: :peg} = grammar, actions_module, opts) do
    {tokenizer_defs, tokenize_def} = TokenizerCompiler.generate(grammar)
    rule_defs = RuleCompiler.compile(grammar)
    lossless_defs = if opts[:lossless], do: lossless_defs(grammar, actions_module), else: []
    root_fn = RuleCompiler.rule_fn_name(grammar.root)
    capture_shapes = Codegen.capture_shapes_ast(VMRuleCompiler.capture_shapes(grammar))
    root = grammar.root

    quote do
      # `capture_shapes` above is a compile-time-fully-known MapSet map;
      # Dialyzer's success typing infers its exact concrete structure
      # regardless of it being built via `MapSet.new/1`, then flags that
      # as more precise than `Ichor.Actions.capture_shapes()`'s declared
      # opaque `MapSet.t()` -- a known Dialyzer/opaque-type-plus-literal
      # limitation, not a real bug. Some grammars' own token patterns
      # also happen to be total over their own tokenizer candidates,
      # making the shared `:fail` fallback below provably unreachable
      # for those grammars specifically -- also not a real bug, just
      # varies per grammar shape.
      @dialyzer [:no_opaque, :no_match]

      alias Grammar.Native.Runtime.{Parser, Tokenizer}
      alias Grammar.VM.Token

      unquote_splicing(tokenizer_defs)
      unquote_splicing(rule_defs)

      unquote(tokenize_def)
      unquote_splicing(lossless_defs)

      @doc "Matches `input` against the grammar's root rule, requiring the entire (tokenized) input to be consumed. A bare recognizer -- no `Ichor.Actions` involved. `context` is read-only and only ever consulted by a `Grammar.IR.Custom` `@native(...)` node, if the grammar has one."
      @spec parse(String.t(), term()) ::
              {:ok, non_neg_integer(), Ichor.Capture.raw_captures()} | {:error, Ichor.Error.t()}
      def parse(input, context \\ nil) do
        with {:ok, tokens} <- tokenize(input, context) do
          stream = tokens |> Grammar.Source.trimmed(unquote(grammar.skip)) |> List.to_tuple()

          unquote(matched(root_fn, root, quote(do: {:ok, pos, raw_captures})))
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

      @doc "Like `run/2`, but evaluates `input` as a sequence of top-level matches against the root rule, one after another, threading context from each into the next (loading a standard-library file one top-level form at a time is the motivating case -- most grammars only ever need `run/2`)."
      @spec run_sequence(String.t(), Ichor.Actions.context()) ::
              {:ok, [term()], Ichor.Actions.context()}
              | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
      def run_sequence(input, initial_context) do
        with {:ok, tokens} <- tokenize(input, initial_context) do
          do_run_sequence(List.to_tuple(tokens), 0, initial_context, [])
        end
      end

      defp do_run_sequence(stream, pos, ctx, acc) do
        pos = Parser.skip_leading_trivia(stream, pos, unquote(grammar.skip))

        if pos >= tuple_size(stream) do
          {:ok, Enum.reverse(acc), ctx}
        else
          case unquote(root_fn)(stream, pos, [0], ctx) do
            {:ok, new_pos, _ref_stack, raw_captures} ->
              case Ichor.Actions.evaluate(
                     unquote(root),
                     raw_captures,
                     unquote(actions_module),
                     ctx,
                     unquote(capture_shapes)
                   ) do
                {:ok, value, new_ctx} -> do_run_sequence(stream, new_pos, new_ctx, [value | acc])
                {:error, _} = err -> err
              end

            _fail ->
              {:error,
               Ichor.Error.new(
                 message: "input does not match #{inspect(unquote(root))}",
                 stage: :parser
               )}
          end
        end
      end
    end
  end

  # The match of the root over `stream`, as a `case`: `success` where the
  # root consumed the whole stream (`pos` and `raw_captures` bound), the
  # same errors otherwise. Shared by `parse/2` and the lossless match, so
  # the lossless parser fails word for word as the ordinary one does.
  defp matched(root_fn, root, success) do
    quote do
      case unquote(root_fn)(stream, 0, [0], context) do
        {:ok, pos, _ref_stack, raw_captures} when pos == tuple_size(stream) ->
          unquote(success)

        {:ok, pos, _ref_stack, _raw_captures} ->
          {:error, Parser.unexpected_token_error(stream, pos, input)}

        _fail ->
          {line, column} = Grammar.Source.position(stream, 0, input)

          {:error,
           Ichor.Error.new(
             message: "input does not match #{inspect(unquote(root))}",
             stage: :parser,
             line: line,
             column: column,
             source: input
           )}
      end
    end
  end

  # `lossless: true`: the recording set of rule functions
  # (`RuleCompiler.compile/2`), and `parse_lossless/2`/`run_lossless/2`
  # over it. Nothing the ordinary `parse/2` or `run/2` calls is touched.
  defp lossless_defs(grammar, actions_module) do
    root = grammar.root
    root_fn = RuleCompiler.lossless_rule_fn_name(root)
    capture_shapes = Codegen.capture_shapes_ast(VMRuleCompiler.capture_shapes(grammar))

    success =
      quote do
        {raw_captures, record} = Ichor.Syntax.Record.root(unquote(root), pos, raw_captures)
        {:ok, Ichor.Syntax.tree(record, tokens, unquote(grammar.skip)), raw_captures}
      end

    RuleCompiler.compile(grammar, lossless: true) ++
      [
        quote do
          @doc "Like `parse/2`, but returns the lossless tree of `input` (`Ichor.Syntax`): every byte of it, trivia and punctuation included, under every rule that matched. Fails exactly as `parse/2` fails."
          @spec parse_lossless(String.t(), term()) ::
                  {:ok, Ichor.Syntax.Node.t()} | {:error, Ichor.Error.t()}
          def parse_lossless(input, context \\ nil) do
            with {:ok, tree, _raw_captures} <- lossless_match(input, context) do
              {:ok, tree}
            end
          end

          @doc "Like `run/2`, returning the lossless tree of `input` beside the value: `{:ok, value, tree}`, `value` being exactly what `run/2` returns."
          @spec run_lossless(String.t(), Ichor.Actions.context()) ::
                  {:ok, term(), Ichor.Syntax.Node.t()}
                  | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
          def run_lossless(input, initial_context \\ nil) do
            with {:ok, tree, raw_captures} <- lossless_match(input, initial_context),
                 {:ok, value, _context} <-
                   Ichor.Actions.evaluate(
                     unquote(root),
                     raw_captures,
                     unquote(actions_module),
                     initial_context,
                     unquote(capture_shapes)
                   ) do
              {:ok, value, tree}
            end
          end

          defp lossless_match(input, context) do
            with {:ok, tokens} <- tokenize(input, context) do
              stream = tokens |> Grammar.Source.trimmed(unquote(grammar.skip)) |> List.to_tuple()
              unquote(matched(root_fn, root, success))
            end
          end
        end
      ]
  end

  # A grammar tagged `@engine lr`/`@engine glr` never had its left
  # recursion rewritten (`Grammar.Analysis` only does that for `:peg` --
  # see `Aether.Grammar`'s own moduledoc); this is checked here, not left
  # to surface as a runtime hang, since `use Ichor` already raises a
  # `CompileError` for other grammar problems at this same point.
  def generate(%Aether.Grammar{engine: engine}, _actions_module, _opts) do
    raise CompileError,
      description:
        "this grammar is tagged @engine #{engine} -- Grammar.Native only compiles @engine peg grammars; use Grammar.LR/Grammar.GLR instead"
  end
end
