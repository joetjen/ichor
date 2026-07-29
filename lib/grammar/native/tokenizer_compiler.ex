defmodule Grammar.Native.TokenizerCompiler do
  @moduledoc """
  Generates the Tokenizer -> Lexer half of a compiled grammar's `tokenize/2`
  (char-level maximal munch via `Grammar.Native.CharCompiler`, then
  `@keywords`/`@refine` reclassification via the shared, backend-agnostic
  `Grammar.Lexer`) -- extracted once out of `Grammar.Native.generate/2` so
  `Grammar.Native.LR`/`Grammar.Native.GLR` can reuse it unchanged: every
  engine consumes the exact same token stream, only the *parser* half
  differs (direct PEG combinator calls, vs. compiled LR/GLR state
  dispatch).

  The caller supplies its own `alias Grammar.Native.Runtime.Tokenizer`
  (and `Grammar.VM.Token`, for the `@spec`) -- this module only builds
  the quoted defs, it doesn't own the generated module's own alias list.
  """

  alias Grammar.IR
  alias Grammar.Native.{CharCompiler, RuleCompiler}

  @doc """
  Returns `{support_defs, tokenize_def}`: `support_defs` are private
  helpers (`lex_candidates/2` plus every compiled char-matcher
  function) to splice in alongside the caller's own parser defs;
  `tokenize_def` is the public `def tokenize/2` itself.
  """
  @spec generate(Aether.Grammar.t()) :: {[Macro.t()], Macro.t()}
  def generate(grammar) do
    {char_defs, custom_lexemes} = CharCompiler.compile(grammar.tokens)
    lexable = Grammar.VM.lexable_token_order(grammar)
    refiners = Macro.escape(grammar.refiners)
    input = Macro.var(:input, nil)

    # See `Grammar.Native.generate/2`'s own note: `_context` when there
    # are no `Grammar.IR.CustomLexeme` tokens at all, so a grammar
    # without one doesn't generate an "unused variable" warning.
    context =
      if map_size(custom_lexemes) > 0,
        do: Macro.var(:context, nil),
        else: Macro.var(:_context, nil)

    candidates =
      Enum.map(lexable, fn tok_name ->
        case Map.fetch(custom_lexemes, tok_name) do
          {:ok, {module, function, deps}} ->
            custom_lexeme_candidate(tok_name, module, function, deps, input, context)

          :error ->
            fn_name = CharCompiler.fn_name(tok_name)

            quote do
              {unquote(tok_name),
               fn ->
                 case unquote(fn_name)(unquote(input)) do
                   {:ok, text, rest} -> {:ok, text, rest, nil}
                   :fail -> :fail
                 end
               end}
            end
        end
      end)

    lex_candidates_def =
      quote do
        defp lex_candidates(unquote(input), unquote(context)) do
          unquote(candidates)
        end
      end

    tokenize_def =
      quote do
        @doc "Tokenizes `input` completely via maximal munch, applies any `@keywords`/`@refine` rules, or reports the first position nothing matches. `context` is read-only and only ever consulted by a `Grammar.IR.CustomLexeme` `@native(...)` token, if the grammar has one."
        @spec tokenize(String.t(), term()) :: {:ok, [Token.t()]} | {:error, Ichor.Error.t()}
        def tokenize(input, context \\ nil) do
          with {:ok, input} <- Grammar.Source.validate(input),
               {:ok, raw_tokens} <-
                 Tokenizer.tokenize(fn inp -> lex_candidates(inp, context) end, input) do
            Grammar.Lexer.reclassify(raw_tokens, unquote(refiners))
          end
        end
      end

    {char_defs ++ [lex_candidates_def], tokenize_def}
  end

  @doc """
  Does `grammar` have any token-position `@native(...)`
  (`Grammar.IR.CustomLexeme`) with a non-empty dependency list? Those
  dependencies need a "re-lex and match a rule" primitive that only
  exists against `Grammar.Native.RuleCompiler`'s own per-rule generated
  functions (ordinary PEG codegen, one function per rule) --
  `Grammar.Native.LR`/`.GLR` compile rules into per-automaton-state
  functions instead, which have no such per-rule entry point. When this
  is true, the caller (`Grammar.Native.LR`/`.GLR`) splices in
  `Grammar.Native.RuleCompiler.compile/1`'s ordinary PEG rule functions
  too -- unused by its own `parse`/`run`, present only so a dependency
  reference resolves -- exactly mirroring how the *interpreted*
  `Grammar.LR`/`Grammar.GLR` already compile a full
  `Grammar.VM.RuleCompiler` program purely for this same purpose, even
  though their own top-level parse never runs it.
  """
  @spec has_customlexeme_deps?(Aether.Grammar.t()) :: boolean()
  def has_customlexeme_deps?(grammar) do
    Enum.any?(grammar.tokens, fn {_name, ir} -> customlexeme_with_deps?(ir) end)
  end

  defp customlexeme_with_deps?(%IR.CustomLexeme{deps: [_ | _]}), do: true
  defp customlexeme_with_deps?(_), do: false

  # A `Grammar.IR.CustomLexeme`-bodied token: no compiled matcher function
  # exists for it at all (see `Grammar.Native.CharCompiler`'s moduledoc),
  # so its maximal-munch candidate calls `Ichor.CustomLexeme.scan/3`
  # directly, building the re-lex-and-match-a-rule `rule_matchers` it
  # needs by closing over this grammar's own compiled rule functions and
  # `lex_candidates/2` (for the re-lex half, via `Tokenizer.tokenize_prefix/2`
  # -- a dependency rule's own match rarely consumes the *entire* rest of
  # the input, so re-lexing has to tolerate trailing bytes that never
  # form a token at all, unlike an ordinary top-level `tokenize/2` call).
  defp custom_lexeme_candidate(tok_name, module, function, deps, input, context) do
    matcher_entries =
      Enum.map(deps, fn dep ->
        dep_fn = RuleCompiler.rule_fn_name(dep)
        dep_input = Macro.var(:dep_input, nil)

        quote do
          {unquote(dep),
           fn unquote(dep_input) ->
             {:ok, dep_tokens} =
               Tokenizer.tokenize_prefix(
                 fn inp -> lex_candidates(inp, unquote(context)) end,
                 unquote(dep_input)
               )

             dep_stream = List.to_tuple(dep_tokens)

             case unquote(dep_fn)(dep_stream, 0, [0], unquote(context)) do
               {:ok, dep_token_pos, _ref_stack, dep_caps} ->
                 {consumed, _rest} = Enum.split(dep_tokens, dep_token_pos)
                 text = Enum.map_join(consumed, "", & &1.text)

                 rest =
                   binary_part(
                     unquote(dep_input),
                     byte_size(text),
                     byte_size(unquote(dep_input)) - byte_size(text)
                   )

                 {:ok, text, rest, {:rule, unquote(dep), dep_caps}}

               :fail ->
                 :fail
             end
           end}
        end
      end)

    quote do
      {unquote(tok_name),
       fn ->
         rule_matchers = Map.new([unquote_splicing(matcher_entries)])

         case apply(unquote(module), unquote(function), [
                unquote(input),
                unquote(context),
                rule_matchers
              ]) do
           {:ok, text, rest, capture} -> {:ok, text, rest, capture}
           :fail -> :fail
         end
       end}
    end
  end
end
