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

    starts = Enum.map(lexable, &Grammar.FirstChars.of(grammar.tokens, &1))
    lex_candidates_defs = lex_candidates_def(candidates, starts, input, context)

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

    {char_defs ++ lex_candidates_defs, tokenize_def}
  end

  # `lex_candidates/2`: the candidates maximal munch tries at the start of
  # `input`. Only those whose start set (`Grammar.FirstChars`) holds the
  # next character are built at all; a token whose start set is `:any` is
  # always tried. Candidates stay in declaration order, which breaks ties
  # between equally long matches.
  #
  # An ASCII character -- nearly every one in most inputs -- costs one
  # lookup: the 128 of them are sorted, here, into groups with the same
  # candidates, and `lex_ascii_group/1` (one clause per character, which
  # the compiler turns into a jump table) names the group. Any other
  # character asks each candidate's start set in turn. At the end of the
  # input every candidate is handed over, as before -- the tokenizer stops
  # there without trying any.
  defp lex_candidates_def(candidates, starts, input, context) do
    pairs = Enum.zip(candidates, starts)

    ascii =
      for code <- 0..127 do
        for {candidate, start} <- pairs, starts_with?(start, code), do: candidate
      end

    groups = ascii |> Enum.uniq() |> Enum.with_index()
    group_of = Map.new(groups)
    char = Macro.var(:char, nil)

    group_clauses =
      ascii
      |> Enum.with_index()
      |> Enum.map(fn {list, code} ->
        quote do
          defp lex_ascii_group(unquote(code)), do: unquote(Map.fetch!(group_of, list))
        end
      end)

    group_arms =
      Enum.flat_map(groups, fn {list, id} ->
        quote do
          unquote(id) -> unquote(list)
        end
      end)

    # A grammar none of whose tokens can begin beyond ASCII never looks at
    # such a character: it is bound as `_`, so no unused variable is left.
    {beyond, asks?} = beyond_ascii(pairs, char)
    wide_char = if asks?, do: char, else: Macro.var(:_, nil)

    lex_candidates =
      quote do
        defp lex_candidates(unquote(input), unquote(context)) do
          case unquote(input) do
            <<unquote(char)::utf8, _::binary>> when unquote(char) < 128 ->
              case lex_ascii_group(unquote(char)) do
                unquote(group_arms)
              end

            <<unquote(wide_char)::utf8, _::binary>> ->
              unquote(beyond)

            _ ->
              unquote(candidates)
          end
        end
      end

    [lex_candidates | group_clauses]
  end

  defp starts_with?(:any, _code), do: true

  defp starts_with?({:ranges, ranges}, code),
    do: Enum.any?(ranges, fn {lo, hi} -> code in lo..hi end)

  # The candidates for a character beyond ASCII: those whose start set
  # reaches past it, each asked in turn, consed from the last to the
  # first so the list keeps declaration order. Also whether any of them
  # asks, i.e. whether the code looks at `char` at all.
  defp beyond_ascii(pairs, char) do
    acc = Macro.var(:acc, nil)

    steps =
      pairs
      |> Enum.reverse()
      |> Enum.flat_map(fn
        {candidate, :any} ->
          [quote(do: unquote(acc) = [unquote(candidate) | unquote(acc)])]

        {candidate, {:ranges, ranges}} ->
          case Enum.filter(ranges, fn {_lo, hi} -> hi >= 128 end) do
            [] ->
              []

            wide ->
              class = Macro.escape(Grammar.Native.Runtime.Tokenizer.char_class(wide))

              [
                quote do
                  unquote(acc) =
                    if Tokenizer.in_class?(unquote(char), unquote(class)),
                      do: [unquote(candidate) | unquote(acc)],
                      else: unquote(acc)
                end
              ]
          end
      end)

    asks? = Enum.any?(pairs, fn {_candidate, start} -> wide?(start) end)

    code =
      quote do
        unquote(acc) = []
        unquote_splicing(steps)
        unquote(acc)
      end

    {code, asks?}
  end

  defp wide?(:any), do: false
  defp wide?({:ranges, ranges}), do: Enum.any?(ranges, fn {_lo, hi} -> hi >= 128 end)

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

                 # Plain: the scan callback is promised `node_t()`s, and
                 # the positions recorded here count a stream of the
                 # suffix, not the input's.
                 {:ok, text, rest, Ichor.Capture.plain({:rule, unquote(dep), dep_caps})}

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
