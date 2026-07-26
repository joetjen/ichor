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

  alias Grammar.Native.{CharCompiler, RuleCompiler, Runtime}
  alias Grammar.VM.RuleCompiler, as: VMRuleCompiler

  @doc "Generates the full quoted body (lexer + parser + `parse/1` + `run/1,2`) for `grammar`, dispatching to `actions_module`."
  @spec generate(Aether.Grammar.t(), module()) :: Macro.t()
  def generate(%Aether.Grammar{} = grammar, actions_module) do
    char_defs = CharCompiler.compile(grammar.tokens)
    rule_defs = RuleCompiler.compile(grammar)
    lexable = Grammar.VM.lexable_token_order(grammar)
    root_fn = RuleCompiler.rule_fn_name(grammar.root)
    capture_shapes = Macro.escape(VMRuleCompiler.capture_shapes(grammar))
    root = grammar.root
    input = Macro.var(:input, nil)

    candidates =
      Enum.map(lexable, fn tok_name ->
        fn_name = CharCompiler.fn_name(tok_name)

        quote do
          {unquote(tok_name), fn -> unquote(fn_name)(unquote(input)) end}
        end
      end)

    quote do
      alias Grammar.Native.Runtime
      alias Grammar.VM.Token

      unquote_splicing(char_defs)
      unquote_splicing(rule_defs)

      defp lex_candidates(unquote(input)) do
        unquote(candidates)
      end

      @doc "Tokenizes `input` completely via maximal munch, or reports the first position nothing matches."
      @spec tokenize(String.t()) :: {:ok, [Token.t()]} | {:error, Ichor.Error.t()}
      def tokenize(input), do: Runtime.tokenize(&lex_candidates/1, input)

      @doc "Matches `input` against the grammar's root rule, requiring the entire (tokenized) input to be consumed. A bare recognizer -- no `Ichor.Actions` involved."
      @spec parse(String.t()) :: {:ok, non_neg_integer(), map()} | {:error, Ichor.Error.t()}
      def parse(input) do
        with {:ok, tokens} <- tokenize(input) do
          stream = List.to_tuple(tokens)

          case unquote(root_fn)(stream, 0, [0]) do
            {:ok, pos, _ref_stack, raw_captures} when pos == tuple_size(stream) ->
              {:ok, pos, raw_captures}

            {:ok, pos, _ref_stack, _raw_captures} ->
              {:error, Runtime.unexpected_token_error(stream, pos, input)}

            _fail ->
              {:error,
               Ichor.Error.new(
                 message: "input does not match #{inspect(unquote(root))}",
                 stage: :parser,
                 source: input
               )}
          end
        end
      end

      @doc "Like `parse/1`, but runs the match through the compile-time-known Actions module, returning the grammar's actual evaluated result."
      @spec run(String.t(), Ichor.Actions.context()) ::
              {:ok, term()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
      def run(input, initial_context \\ nil) do
        with {:ok, _pos, raw_captures} <- parse(input),
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
        with {:ok, tokens} <- tokenize(input) do
          do_run_sequence(List.to_tuple(tokens), 0, initial_context, [])
        end
      end

      defp do_run_sequence(stream, pos, ctx, acc) do
        pos = Runtime.skip_leading_trivia(stream, pos, unquote(grammar.skip))

        if pos >= tuple_size(stream) do
          {:ok, Enum.reverse(acc), ctx}
        else
          case unquote(root_fn)(stream, pos, [0]) do
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
end
