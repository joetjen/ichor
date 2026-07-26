defmodule Aether.Parser do
  @moduledoc """
  Parses `.aether` source (via `Aether.Lexer`) into an `Aether.Grammar` --
  every pragma, token, and rule resolved to `Grammar.IR`.

  This module owns every piece of Aether semantics that isn't pure lexical
  scanning: the token/rule reference split (`ALL_CAPS` names a token,
  `snake-case` names a rule), predefined-token override-before-use
  tracking, POSIX bracket classes, `@skip`/`@noskip`/`~` splicing,
  `@indent`/`@samecol`, `/pattern/` regex-literal desugaring, and
  inline-literal auto-promotion (a bare string in a rule body becomes a
  reference to a compiler-generated anonymous token, since only tokens
  ever get lexed).
  """

  alias Aether.{Lexer, Token}
  alias Grammar.IR
  alias Ichor.Error

  @predefined [:DIGIT, :ALPHA, :ALNUM, :SPACE, :HEX]

  @posix_names %{
    "alpha" => :alpha,
    "alnum" => :alnum,
    "digit" => :digit,
    "space" => :space,
    "hex" => :hex
  }

  @regex_escape_literal_chars [?., ?[, ?], ?^, ?-, ?*, ?+, ??, ?|, ?(, ?), ?{, ?}, ?\\, ?/]

  @doc "Parses `source` into a fully compiled `Aether.Grammar`."
  @spec parse(String.t(), String.t() | nil) :: {:ok, Aether.Grammar.t()} | {:error, Error.t()}
  def parse(source, file \\ nil) do
    with {:ok, tokens} <- Lexer.lex(source, file) do
      state = new_state(source, file, tokens)

      with {:ok, state} <- parse_header(state),
           {:ok, state} <- parse_definitions(state) do
        finalize(state)
      else
        {:error, %Error{}} = err -> err
      end
    end
  end

  # ---- state ----------------------------------------------------------------

  defp new_state(source, file, tokens) do
    %{
      source: source,
      file: file,
      tokens: tokens,
      name: nil,
      root: nil,
      root_pos: nil,
      skip_mode: :default,
      skip_pos: nil,
      case_insensitive: false,
      seen_pragmas: MapSet.new(),
      predefined_overrides: Map.new(@predefined, &{&1, nil}),
      predefined_used_at: Map.new(@predefined, &{&1, nil}),
      tokens_defs: %{},
      token_order: [],
      rules_defs: %{},
      declared_token_names: MapSet.new(),
      declared_rule_names: MapSet.new(),
      anon_by_key: %{},
      anon_counter: 0,
      anon_tokens: MapSet.new()
    }
  end

  # ---- token stream helpers ---------------------------------------------

  defp peek(state), do: hd(state.tokens)
  defp peek_type(state), do: peek(state).type
  defp peek_at(state, n), do: Enum.at(state.tokens, n)
  defp advance(state), do: %{state | tokens: tl(state.tokens)}

  defp expect(state, type, what) do
    tok = peek(state)

    if tok.type == type do
      {:ok, tok, advance(state)}
    else
      {:error, err(state, tok, "expected #{what}, found #{describe(tok)}")}
    end
  end

  defp describe(%Token{type: :eof}), do: "end of input"
  defp describe(%Token{type: :upper_ident, value: v}), do: "token name #{inspect(v)}"
  defp describe(%Token{type: :lower_ident, value: v}), do: "rule name #{inspect(v)}"
  defp describe(%Token{type: :string, value: %{text: t}}), do: "string #{inspect(t)}"
  defp describe(%Token{type: :number, value: v}), do: "number #{v}"
  defp describe(%Token{type: :char_class}), do: "a character class"
  defp describe(%Token{type: :regex}), do: "a regex literal"
  defp describe(%Token{type: type}), do: "'#{punct(type)}'"

  defp punct(:pipe), do: "|"
  defp punct(:star), do: "*"
  defp punct(:plus), do: "+"
  defp punct(:question), do: "?"
  defp punct(:lbrace), do: "{"
  defp punct(:rbrace), do: "}"
  defp punct(:comma), do: ","
  defp punct(:amp), do: "&"
  defp punct(:bang), do: "!"
  defp punct(:colon), do: ":"
  defp punct(:lparen), do: "("
  defp punct(:rparen), do: ")"
  defp punct(:tilde), do: "~"
  defp punct(:dot), do: "."
  defp punct(:define), do: ":="
  defp punct(other), do: to_string(other)

  defp err(state, %Token{line: line, column: col}, message),
    do: err_at(state, {line, col}, message)

  defp err_at(state, {line, col}, message) do
    Error.new(
      message: message,
      stage: :parser,
      file: state.file,
      line: line,
      column: col,
      source: state.source
    )
  end

  # A leaf node's source position, for later stages (the analysis pass in
  # particular) to point errors back at real grammar locations. Only
  # leaf/quantifier nodes get a span here -- composite nodes (Seq, Choice,
  # ...) fall back to a descendant's span when something needs to report a
  # location on them.
  defp span({line, col}), do: %IR.Meta{source_span: {line, col, 0}}

  # ---- header: @grammar @root @skip/@noskip @case_insensitive ---------------

  defp parse_header(state) do
    with {:ok, state} <- expect_grammar(state),
         {:ok, state} <- expect_root(state) do
      parse_optional_pragmas(state)
    end
  end

  defp expect_grammar(state) do
    case peek_type(state) do
      :at_grammar ->
        state = advance(state)

        with {:ok, tok, state} <- expect(state, :string, "a grammar name string after @grammar") do
          {:ok, %{state | name: tok.value.text}}
        end

      _ ->
        {:error, err(state, peek(state), "expected @grammar at the start of the file")}
    end
  end

  defp expect_root(state) do
    case peek_type(state) do
      :at_root ->
        state = advance(state)

        with {:ok, tok, state} <- expect(state, :lower_ident, "a rule name after @root") do
          {:ok, %{state | root: String.to_atom(tok.value), root_pos: {tok.line, tok.column}}}
        end

      _ ->
        {:error, err(state, peek(state), "expected @root after @grammar")}
    end
  end

  defp parse_optional_pragmas(state) do
    case peek_type(state) do
      :at_skip -> parse_skip_pragma(state)
      :at_noskip -> parse_noskip_pragma(state)
      :at_case_insensitive -> parse_case_insensitive_pragma(state)
      _ -> {:ok, state}
    end
  end

  defp parse_skip_pragma(state) do
    if MapSet.member?(state.seen_pragmas, :skip_or_noskip) do
      {:error, err(state, peek(state), "@skip/@noskip may only be given once")}
    else
      state = advance(state)

      with {:ok, tok, state} <- expect(state, :upper_ident, "a token name after @skip") do
        name = String.to_atom(tok.value)
        pos = {tok.line, tok.column}

        state =
          state
          |> mark_pragma_seen(:skip_or_noskip)
          |> Map.put(:skip_mode, {:custom, name})
          |> Map.put(:skip_pos, pos)
          |> mark_predefined_used(name, pos)

        parse_optional_pragmas(state)
      end
    end
  end

  defp parse_noskip_pragma(state) do
    if MapSet.member?(state.seen_pragmas, :skip_or_noskip) do
      {:error, err(state, peek(state), "@skip/@noskip may only be given once")}
    else
      state =
        state
        |> advance()
        |> mark_pragma_seen(:skip_or_noskip)
        |> Map.put(:skip_mode, :none)

      parse_optional_pragmas(state)
    end
  end

  defp parse_case_insensitive_pragma(state) do
    if MapSet.member?(state.seen_pragmas, :case_insensitive) do
      {:error, err(state, peek(state), "@case_insensitive may only be given once")}
    else
      state =
        state
        |> advance()
        |> mark_pragma_seen(:case_insensitive)
        |> Map.put(:case_insensitive, true)

      parse_optional_pragmas(state)
    end
  end

  defp mark_pragma_seen(state, key),
    do: %{state | seen_pragmas: MapSet.put(state.seen_pragmas, key)}

  # ---- top-level definitions --------------------------------------------

  defp parse_definitions(state) do
    case peek_type(state) do
      :eof ->
        {:ok, state}

      :upper_ident ->
        with {:ok, state} <- parse_token_def(state), do: parse_definitions(state)

      :lower_ident ->
        with {:ok, state} <- parse_rule_def(state), do: parse_definitions(state)

      _ ->
        {:error, err(state, peek(state), "expected a token or rule definition (NAME := ...)")}
    end
  end

  defp parse_token_def(state) do
    name_tok = peek(state)
    name = String.to_atom(name_tok.value)
    pos = {name_tok.line, name_tok.column}
    state = advance(state)

    with {:ok, _define, state} <-
           expect(state, :define, "':=' after token name #{name_tok.value}"),
         {:ok, ir, state} <- parse_choice(state, :token, pos) do
      register_token(state, name, ir, pos)
    end
  end

  defp parse_rule_def(state) do
    name_tok = peek(state)
    name = String.to_atom(name_tok.value)
    pos = {name_tok.line, name_tok.column}
    state = advance(state)

    with {:ok, _define, state} <-
           expect(state, :define, "':=' after rule name #{name_tok.value}"),
         {:ok, ir, state} <- parse_choice(state, :rule, pos) do
      register_rule(state, name, ir, pos)
    end
  end

  defp register_token(state, name, ir, pos) do
    cond do
      name in @predefined ->
        cond do
          state.predefined_used_at[name] != nil ->
            {used_line, used_col} = state.predefined_used_at[name]

            {:error,
             err_at(
               state,
               pos,
               "cannot override #{name}: already used at line #{used_line}, column #{used_col}"
             )}

          state.predefined_overrides[name] != nil ->
            {:error, err_at(state, pos, "#{name} may only be declared once")}

          true ->
            {:ok,
             %{
               state
               | predefined_overrides: Map.put(state.predefined_overrides, name, ir),
                 token_order: state.token_order ++ [name]
             }}
        end

      MapSet.member?(state.declared_token_names, name) ->
        {:error, err_at(state, pos, "token #{name} is already declared")}

      true ->
        {:ok,
         %{
           state
           | tokens_defs: Map.put(state.tokens_defs, name, ir),
             declared_token_names: MapSet.put(state.declared_token_names, name),
             token_order: state.token_order ++ [name]
         }}
    end
  end

  defp register_rule(state, name, ir, pos) do
    if MapSet.member?(state.declared_rule_names, name) do
      {:error, err_at(state, pos, "rule #{name} is already declared")}
    else
      {:ok,
       %{
         state
         | rules_defs: Map.put(state.rules_defs, name, ir),
           declared_rule_names: MapSet.put(state.declared_rule_names, name)
       }}
    end
  end

  # ---- predefined-token override/use bookkeeping ---------------------------
  # DIGIT/ALPHA/ALNUM/SPACE/HEX ship with sane defaults but can be
  # redeclared -- as long as that happens before the grammar author (or an
  # auto-triggered use, like @skip's implicit SPACE) actually references
  # one. Redeclaring one *after* it's been used would silently change
  # meaning depending on file order, so it's simply rejected.

  defp mark_predefined_used(state, name, pos) when name in @predefined do
    state =
      if state.predefined_used_at[name] == nil do
        %{state | predefined_used_at: Map.put(state.predefined_used_at, name, pos)}
      else
        state
      end

    if name == :ALNUM do
      state |> mark_predefined_used(:DIGIT, pos) |> mark_predefined_used(:ALPHA, pos)
    else
      state
    end
  end

  defp mark_predefined_used(state, _name, _pos), do: state

  defp default_digit, do: IR.char_class([{?0, ?9}])
  defp default_alpha, do: IR.char_class([{?a, ?z}, {?A, ?Z}])
  defp default_space, do: IR.char_class([{?\s, ?\s}, {?\t, ?\t}, {?\r, ?\r}, {?\n, ?\n}])
  defp default_hex, do: IR.char_class([{?a, ?f}, {?A, ?F}, {?0, ?9}])

  # ---- expression grammar: choice > sequence > term > postfix > primary ----

  # choice := sequence (PIPE sequence)*
  defp parse_choice(state, context, pos) do
    with {:ok, first, state} <- parse_sequence(state, context, pos) do
      parse_choice_rest(state, context, pos, [first])
    end
  end

  defp parse_choice_rest(state, context, pos, acc) do
    case peek_type(state) do
      :pipe ->
        state = advance(state)

        with {:ok, next, state} <- parse_sequence(state, context, pos) do
          parse_choice_rest(state, context, pos, [next | acc])
        end

      _ ->
        case Enum.reverse(acc) do
          [one] -> {:ok, one, state}
          many -> {:ok, IR.choice(many), state}
        end
    end
  end

  # sequence := gap_marked_term+, with @skip splicing applied for :rule context
  defp parse_sequence(state, context, pos) do
    parse_sequence_terms(state, context, pos, [])
  end

  defp parse_sequence_terms(state, context, pos, acc) do
    if continues_sequence?(state) do
      with {:ok, suppress, ir, state} <- parse_gap_marked_term(state, context, pos) do
        parse_sequence_terms(state, context, pos, [{ir, suppress} | acc])
      end
    else
      case Enum.reverse(acc) do
        [] ->
          {:error,
           err(state, peek(state), "expected an expression, found #{describe(peek(state))}")}

        terms ->
          {ir, state} = build_sequence(terms, context, state)
          {:ok, ir, state}
      end
    end
  end

  defp starts_term?(type),
    do:
      type in [
        :tilde,
        :amp,
        :bang,
        :upper_ident,
        :lower_ident,
        :string,
        :char_class,
        :regex,
        :dot,
        :lparen,
        :at_indent,
        :at_samecol
      ]

  # An identifier immediately followed by ":=" can never be a reference
  # continuing the current sequence -- ":=" never appears inside an
  # expression, so this always means "the next definition has begun,"
  # not "this sequence keeps going." Without this lookahead, a definition
  # body could never tell where it ends, since a bare identifier is
  # otherwise a perfectly valid next sequence term.
  defp continues_sequence?(state) do
    case peek(state) do
      %Token{type: t} when t in [:upper_ident, :lower_ident] ->
        not match?(%Token{type: :define}, peek_at(state, 1))

      %Token{type: t} ->
        starts_term?(t)
    end
  end

  defp parse_gap_marked_term(state, context, pos) do
    case peek_type(state) do
      :tilde ->
        tilde_tok = peek(state)

        cond do
          context == :token ->
            {:error,
             err(
               state,
               tilde_tok,
               "~ is only valid in rule bodies -- skip-splicing never applies inside a token"
             )}

          state.skip_mode == :none ->
            {:error,
             err(state, tilde_tok, "~ requires an active @skip; this grammar uses @noskip")}

          true ->
            state = advance(state)

            with {:ok, ir, state} <- parse_term(state, context, pos) do
              case ir do
                %IR.RuleRef{} ->
                  {:ok, true, ir, state}

                _ ->
                  {:error,
                   err(
                     state,
                     tilde_tok,
                     "~ may only prefix a bare token or rule name, with no capture and no quantifier"
                   )}
              end
            end
        end

      _ ->
        with {:ok, ir, state} <- parse_term(state, context, pos) do
          {:ok, false, ir, state}
        end
    end
  end

  # term := (lower_ident COLON)? postfix
  defp parse_term(state, context, pos) do
    case peek(state) do
      %Token{type: :lower_ident, value: name} ->
        case peek_at(state, 1) do
          %Token{type: :colon} ->
            state = state |> advance() |> advance()

            with {:ok, inner, state} <- parse_postfix(state, context, pos) do
              {:ok, IR.capture(String.to_atom(name), inner), state}
            end

          _ ->
            parse_postfix(state, context, pos)
        end

      _ ->
        parse_postfix(state, context, pos)
    end
  end

  # postfix := (AMP | BANG)? primary quantifier?
  defp parse_postfix(state, context, pos) do
    case peek_type(state) do
      :amp ->
        state = advance(state)

        with {:ok, inner, state} <- parse_primary(state, context, pos) do
          {:ok, IR.and_pred(inner), state}
        end

      :bang ->
        state = advance(state)

        with {:ok, inner, state} <- parse_primary(state, context, pos) do
          {:ok, IR.not_pred(inner), state}
        end

      _ ->
        with {:ok, inner, state} <- parse_primary(state, context, pos) do
          parse_quantifier_suffix(inner, context, state)
        end
    end
  end

  # `X*`/`X+`/`X{n,m}` need the *same* skip-splicing as an explicit
  # sequence: "every rule's sequence elements get SPACE* auto-spliced
  # between them" applies just as much to the elements of a
  # repetition (each one is, after all, another occurrence of a sequence
  # element) as to a literally-written `a b c`. Without this, `form*`
  # could only ever match adjacent, unseparated occurrences -- fatal for
  # something like the LISP grammar's `list := LPAREN form* RPAREN`,
  # which needs whitespace tolerated *between* forms, not just around the
  # parens. All three quantifiers reduce to one general "skip-separated
  # repetition, min to max times" shape (`*` = 0..infinity, `+` =
  # 1..infinity, `{n,m}` = n..m).
  defp parse_quantifier_suffix(ir, context, state) do
    tok = peek(state)
    at = span({tok.line, tok.column})

    case tok.type do
      :star ->
        {ir2, state} = wrap_repetition(ir, context, state, at, 0, :infinity)
        {:ok, ir2, advance(state)}

      :plus ->
        {ir2, state} = wrap_repetition(ir, context, state, at, 1, :infinity)
        {:ok, ir2, advance(state)}

      :question ->
        {:ok, IR.opt(ir, at), advance(state)}

      :lbrace ->
        parse_bound(ir, context, at, advance(state))

      _ ->
        {:ok, ir, state}
    end
  end

  defp parse_bound(ir, context, at, state) do
    with {:ok, min_tok, state} <- expect(state, :number, "a number after '{'") do
      case peek_type(state) do
        :rbrace ->
          {ir2, state} = wrap_repetition(ir, context, state, at, min_tok.value, min_tok.value)
          {:ok, ir2, advance(state)}

        :comma ->
          state = advance(state)

          case peek_type(state) do
            :number ->
              max_tok = peek(state)
              state = advance(state)

              with {:ok, _rb, state} <-
                     expect(state, :rbrace, "'}' to close '{#{min_tok.value},#{max_tok.value}'") do
                {ir2, state} =
                  wrap_repetition(ir, context, state, at, min_tok.value, max_tok.value)

                {:ok, ir2, state}
              end

            :rbrace ->
              {ir2, state} = wrap_repetition(ir, context, state, at, min_tok.value, :infinity)
              {:ok, ir2, advance(state)}

            _ ->
              {:error, err(state, peek(state), "expected a number or '}' in repetition bound")}
          end

        _ ->
          {:error, err(state, peek(state), "expected ',' or '}' in repetition bound")}
      end
    end
  end

  defp skip_splicing?(context, state), do: context == :rule and state.skip_mode != :none

  defp skip_ref(state, at) do
    name = skip_token_name(state)
    {line, col, _len} = at.source_span

    state =
      if state.skip_mode == :default,
        do: mark_predefined_used(state, :SPACE, {line, col}),
        else: state

    {IR.rule_ref(name), state}
  end

  # `ir{min,max}`, skip-separated: `ir`, then `min - 1` more mandatory
  # skip-preceded copies, then up to `max - min` further optional ones
  # (unbounded, for `max == :infinity`). When `min == 0`, the very first
  # `ir` is itself optional, so the whole thing is wrapped in one more
  # `Opt` -- everything after it already carries its own leading skip, so
  # nesting it inside that `Opt` doesn't change what it means.
  defp wrap_repetition(ir, context, state, at, min, max) do
    if skip_splicing?(context, state) and {min, max} != {0, 0} do
      {skip_ref, state} = skip_ref(state, at)
      unit = IR.seq([IR.star(skip_ref), ir])

      extra_min = max(min - 1, 0)
      extra_max = if max == :infinity, do: :infinity, else: max - 1

      extra =
        if {extra_min, extra_max} == {0, 0},
          do: [],
          else: [IR.rep(unit, extra_min, extra_max, at)]

      body = IR.seq([ir | extra])
      ir2 = if min == 0, do: IR.opt(body, at), else: body
      {ir2, state}
    else
      {bare_repetition(ir, min, max, at), state}
    end
  end

  # No skip-splicing needed here (either @noskip, a token body, or a
  # degenerate {0,0}): reconstruct the exact node `*`/`+`/`{n,m}` would
  # have produced on their own, rather than always falling through to the
  # more general `Rep` -- `Grammar.Analysis`'s empty-repetition lint (and
  # anything else pattern-matching on node shape) specifically looks for
  # `Star`/`Plus`, and a plain `X*` should still produce one.
  defp bare_repetition(ir, 0, :infinity, at), do: IR.star(ir, at)
  defp bare_repetition(ir, 1, :infinity, at), do: IR.plus(ir, at)
  defp bare_repetition(ir, min, max, at), do: IR.rep(ir, min, max, at)

  # primary: literal | char_class | regex | . | UPPER_IDENT | lower_ident | "(" choice ")" | @indent(...) | @samecol(...)
  defp parse_primary(state, context, pos) do
    case peek(state) do
      %Token{type: :string, value: %{text: text, case: case_flag}, line: line, column: col} ->
        state = advance(state)
        insensitive = effective_case_insensitive?(state, case_flag)
        ir = desugar_literal(text, insensitive, {line, col})

        case context do
          :token -> {:ok, ir, state}
          :rule -> promote_inline_literal(state, ir, text, insensitive, {line, col})
        end

      %Token{type: :char_class} = tok ->
        if context != :token do
          {:error,
           err(
             state,
             tok,
             "rules may not contain an inline character class -- give it a named TOKEN instead"
           )}
        else
          state = advance(state)
          desugar_char_class(tok.value, {tok.line, tok.column}, state)
        end

      %Token{type: :regex} = tok ->
        if context != :token do
          {:error,
           err(
             state,
             tok,
             "rules may not contain an inline /pattern/ -- give it a named TOKEN instead"
           )}
        else
          state = advance(state)
          desugar_regex(tok.value, {tok.line, tok.column}, state)
        end

      %Token{type: :dot} = tok ->
        if context != :token do
          {:error,
           err(state, tok, "rules may not contain '.' directly -- give it a named TOKEN instead")}
        else
          {:ok, IR.any(span({tok.line, tok.column})), advance(state)}
        end

      %Token{type: :upper_ident, value: v, line: line, column: col} ->
        name = String.to_atom(v)
        state = state |> advance() |> mark_predefined_used(name, {line, col})
        {:ok, IR.rule_ref(name, span({line, col})), state}

      %Token{type: :lower_ident, value: v, line: line, column: col} = tok ->
        if context == :token do
          {:error,
           err(state, tok, "a token body may only reference other tokens, not rule #{inspect(v)}")}
        else
          {:ok, IR.rule_ref(String.to_atom(v), span({line, col})), advance(state)}
        end

      %Token{type: :lparen} ->
        state = advance(state)

        with {:ok, inner, state} <- parse_choice(state, context, pos),
             {:ok, _rp, state} <- expect(state, :rparen, "')' to close '('") do
          {:ok, inner, state}
        end

      %Token{type: :at_indent} = tok ->
        parse_indent_like(state, tok, context, pos, :indent)

      %Token{type: :at_samecol} = tok ->
        parse_indent_like(state, tok, context, pos, :samecol)

      tok ->
        {:error, err(state, tok, "expected an expression, found #{describe(tok)}")}
    end
  end

  # `@indent(expr)`/`@samecol(expr)`. Also accepts a bare single term with
  # no parens (`@samecol pair`) as sugar for wrapping just that one term.
  defp parse_indent_like(state, tok, context, pos, kind) do
    if context != :rule do
      {:error, err(state, tok, "@#{kind} is only valid in rule bodies")}
    else
      state = advance(state)

      case peek_type(state) do
        :lparen ->
          state = advance(state)

          with {:ok, inner, state} <- parse_choice(state, :rule, pos),
               {:ok, _rp, state} <- expect(state, :rparen, "')' to close @#{kind}(...)") do
            {:ok, IR.indent(inner, kind), state}
          end

        _ ->
          with {:ok, inner, state} <- parse_postfix(state, context, pos) do
            {:ok, IR.indent(inner, kind), state}
          end
      end
    end
  end

  defp effective_case_insensitive?(_state, :insensitive), do: true
  defp effective_case_insensitive?(_state, :sensitive), do: false
  defp effective_case_insensitive?(state, :default), do: state.case_insensitive

  # ---- inline literal auto-promotion ---------------------------------------
  # A rule body can write a bare `"SELECT"` directly, but only tokens ever
  # participate in lexing -- so each distinct (text, case-sensitivity) pair
  # gets hoisted into a compiler-generated `ANON_n` token the first time
  # it's seen, and every later occurrence of the exact same literal reuses
  # that same token rather than minting a new one.

  defp promote_inline_literal(state, ir, text, insensitive, pos) do
    key = {text, insensitive}

    case Map.fetch(state.anon_by_key, key) do
      {:ok, name} ->
        {:ok, IR.rule_ref(name, span(pos)), state}

      :error ->
        {name, state} = fresh_anon_name(state)

        state = %{
          state
          | anon_by_key: Map.put(state.anon_by_key, key, name),
            tokens_defs: Map.put(state.tokens_defs, name, ir),
            declared_token_names: MapSet.put(state.declared_token_names, name),
            token_order: state.token_order ++ [name],
            anon_tokens: MapSet.put(state.anon_tokens, name)
        }

        {:ok, IR.rule_ref(name, span(pos)), state}
    end
  end

  defp fresh_anon_name(state) do
    n = state.anon_counter + 1
    name = String.to_atom("ANON_#{n}")
    state = %{state | anon_counter: n}

    if MapSet.member?(state.declared_token_names, name) do
      fresh_anon_name(state)
    else
      {name, state}
    end
  end

  # ---- literal case-insensitivity desugaring ---------------------------------

  defp desugar_literal(text, false, pos), do: IR.literal(text, span(pos))

  defp desugar_literal(text, true, pos) do
    case text |> String.graphemes() |> Enum.map(&case_insensitive_node(&1, pos)) do
      [one] -> one
      nodes -> IR.seq(nodes)
    end
  end

  defp case_insensitive_node(grapheme, pos) do
    down = String.downcase(grapheme)
    up = String.upcase(grapheme)

    with true <- down != up,
         <<down_cp::utf8>> <- down,
         <<up_cp::utf8>> <- up do
      IR.char_class([{down_cp, down_cp}, {up_cp, up_cp}], span(pos))
    else
      _ -> IR.literal(grapheme, span(pos))
    end
  end

  # ---- character classes: [...] / [^...] / [:posix:] (sections 3.5/3.6) -----

  defp desugar_char_class(%{negate: negate, items: items}, pos, state) do
    {plain, posix, state} = split_class_items(items, pos, state)

    alternatives =
      if(plain == [], do: [], else: [IR.char_class(Enum.reverse(plain), span(pos))]) ++
        Enum.reverse(posix)

    positive =
      case alternatives do
        [] -> IR.char_class([], span(pos))
        [one] -> one
        many -> IR.choice(many, span(pos))
      end

    ir =
      if negate,
        do: IR.seq([IR.not_pred(positive, span(pos)), IR.any(span(pos))], span(pos)),
        else: positive

    {:ok, ir, state}
  end

  defp split_class_items(items, pos, state) do
    Enum.reduce(items, {[], [], state}, fn item, {plain, posix, state} ->
      case item do
        {:range, a, b} ->
          {[{a, b} | plain], posix, state}

        {:char, c} ->
          {[{c, c} | plain], posix, state}

        {:posix, name} ->
          atom = posix_atom(name)
          state = mark_predefined_used(state, atom, pos)
          {plain, [IR.rule_ref(atom, span(pos)) | posix], state}
      end
    end)
  end

  defp posix_atom(:alpha), do: :ALPHA
  defp posix_atom(:alnum), do: :ALNUM
  defp posix_atom(:digit), do: :DIGIT
  defp posix_atom(:space), do: :SPACE
  defp posix_atom(:hex), do: :HEX

  # ---- /pattern/ regex literal desugaring ----------------------------------
  # A convenience sugar for token bodies only: `/foo|bar/` desugars entirely
  # into ordinary `Grammar.IR` (Choice/Seq/Star/...), so nothing downstream
  # ever needs to know regex syntax existed. Deliberately not a full regex
  # engine -- anchors, backreferences, and named groups are all rejected
  # outright, since none of them have a meaningful desugaring to PEG-style
  # matching primitives.

  defp desugar_regex(pattern, pos, state) do
    case regex_alternatives(pattern, pos, state) do
      {:ok, [], "", _state} ->
        {:error, err_at(state, pos, "empty /pattern/ literal")}

      {:ok, alts, "", state} ->
        {:ok, wrap_alts(alts), state}

      {:ok, _alts, rest, _state} ->
        {:error, err_at(state, pos, "unexpected #{inspect(rest)} in /pattern/ literal")}

      {:error, msg} ->
        {:error, err_at(state, pos, msg)}
    end
  end

  defp wrap_alts([one]), do: one
  defp wrap_alts(many), do: IR.choice(many)

  defp regex_alternatives(text, pos, state) do
    with {:ok, first, rest, state} <- regex_alternative(text, pos, state) do
      regex_alternatives_rest(rest, pos, state, [first])
    end
  end

  defp regex_alternatives_rest(<<"|", rest::binary>>, pos, state, acc) do
    with {:ok, next, rest2, state} <- regex_alternative(rest, pos, state) do
      regex_alternatives_rest(rest2, pos, state, [next | acc])
    end
  end

  defp regex_alternatives_rest(rest, _pos, state, acc), do: {:ok, Enum.reverse(acc), rest, state}

  defp regex_alternative(text, pos, state), do: regex_terms(text, pos, state, [])

  defp regex_terms(text, pos, state, acc) do
    if regex_term_start?(text) do
      with {:ok, term, rest, state} <- regex_term(text, pos, state) do
        regex_terms(rest, pos, state, [term | acc])
      end
    else
      ir =
        case Enum.reverse(acc) do
          [] -> IR.literal("", span(pos))
          [one] -> one
          many -> IR.seq(many)
        end

      {:ok, ir, text, state}
    end
  end

  defp regex_term_start?(<<>>), do: false
  defp regex_term_start?(<<c, _::binary>>) when c in [?|, ?)], do: false
  defp regex_term_start?(_), do: true

  defp regex_term(text, pos, state) do
    with {:ok, atom_ir, rest, state} <- regex_atom(text, pos, state) do
      regex_quantifier(atom_ir, rest, state)
    end
  end

  defp regex_quantifier(ir, <<"*", rest::binary>>, state), do: {:ok, IR.star(ir), rest, state}
  defp regex_quantifier(ir, <<"+", rest::binary>>, state), do: {:ok, IR.plus(ir), rest, state}
  defp regex_quantifier(ir, <<"?", rest::binary>>, state), do: {:ok, IR.opt(ir), rest, state}

  defp regex_quantifier(ir, <<"{", rest::binary>>, state) do
    case regex_number(rest) do
      {:ok, min, rest2} -> regex_bound_rest(ir, min, rest2, state)
      {:error, _} -> {:error, "invalid repetition bound in /pattern/"}
    end
  end

  defp regex_quantifier(ir, rest, state), do: {:ok, ir, rest, state}

  defp regex_bound_rest(ir, min, <<",", rest::binary>>, state) do
    case regex_number(rest) do
      {:ok, max, <<"}", rest2::binary>>} ->
        {:ok, IR.rep(ir, min, max), rest2, state}

      {:error, _} ->
        case rest do
          <<"}", rest2::binary>> -> {:ok, IR.rep(ir, min, :infinity), rest2, state}
          _ -> {:error, "invalid repetition bound in /pattern/"}
        end
    end
  end

  defp regex_bound_rest(ir, min, <<"}", rest::binary>>, state),
    do: {:ok, IR.rep(ir, min, min), rest, state}

  defp regex_bound_rest(_ir, _min, _rest, _state),
    do: {:error, "invalid repetition bound in /pattern/"}

  defp regex_number(<<c, _::binary>> = text) when c in ?0..?9 do
    {digits, rest} = take_digits(text, [])
    {:ok, String.to_integer(digits), rest}
  end

  defp regex_number(_), do: {:error, :no_number}

  defp take_digits(<<c, rest::binary>>, acc) when c in ?0..?9, do: take_digits(rest, [c | acc])
  defp take_digits(rest, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}

  defp regex_alternatives_wrapped(rest, pos, state) do
    with {:ok, alts, rest2, state} <- regex_alternatives(rest, pos, state) do
      case rest2 do
        <<")", rest3::binary>> -> {:ok, wrap_alts(alts), rest3, state}
        _ -> {:error, "expected ')' in /pattern/"}
      end
    end
  end

  defp regex_atom(<<"^", _::binary>>, _pos, _state),
    do: {:error, "anchors (^) are not supported in /pattern/"}

  defp regex_atom(<<"$", _::binary>>, _pos, _state),
    do: {:error, "anchors ($) are not supported in /pattern/"}

  defp regex_atom(<<"(?=", rest::binary>>, pos, state) do
    with {:ok, inner, rest2, state} <- regex_alternatives_wrapped(rest, pos, state) do
      {:ok, IR.and_pred(inner, span(pos)), rest2, state}
    end
  end

  defp regex_atom(<<"(?!", rest::binary>>, pos, state) do
    with {:ok, inner, rest2, state} <- regex_alternatives_wrapped(rest, pos, state) do
      {:ok, IR.not_pred(inner, span(pos)), rest2, state}
    end
  end

  defp regex_atom(<<"(?<", _::binary>>, _pos, _state) do
    {:error, "named groups are not supported in /pattern/ -- tokens don't carry captures"}
  end

  defp regex_atom(<<"(", rest::binary>>, pos, state),
    do: regex_alternatives_wrapped(rest, pos, state)

  defp regex_atom(<<"[", rest::binary>>, pos, state) do
    case regex_char_class(rest) do
      {:ok, value, rest2} ->
        with {:ok, ir, state} <- desugar_char_class(value, pos, state) do
          {:ok, ir, rest2, state}
        end

      {:error, _} = err ->
        err
    end
  end

  defp regex_atom(<<"\\d", rest::binary>>, pos, state),
    do: {:ok, IR.rule_ref(:DIGIT, span(pos)), rest, mark_predefined_used(state, :DIGIT, pos)}

  defp regex_atom(<<"\\w", rest::binary>>, pos, state),
    do: {:ok, IR.rule_ref(:ALNUM, span(pos)), rest, mark_predefined_used(state, :ALNUM, pos)}

  defp regex_atom(<<"\\s", rest::binary>>, pos, state),
    do: {:ok, IR.rule_ref(:SPACE, span(pos)), rest, mark_predefined_used(state, :SPACE, pos)}

  defp regex_atom(<<"\\h", rest::binary>>, pos, state),
    do: {:ok, IR.rule_ref(:HEX, span(pos)), rest, mark_predefined_used(state, :HEX, pos)}

  defp regex_atom(<<"\\D", rest::binary>>, pos, state),
    do: {:ok, negated_ref(:DIGIT, pos), rest, mark_predefined_used(state, :DIGIT, pos)}

  defp regex_atom(<<"\\W", rest::binary>>, pos, state),
    do: {:ok, negated_ref(:ALNUM, pos), rest, mark_predefined_used(state, :ALNUM, pos)}

  defp regex_atom(<<"\\S", rest::binary>>, pos, state),
    do: {:ok, negated_ref(:SPACE, pos), rest, mark_predefined_used(state, :SPACE, pos)}

  defp regex_atom(<<"\\H", rest::binary>>, pos, state),
    do: {:ok, negated_ref(:HEX, pos), rest, mark_predefined_used(state, :HEX, pos)}

  defp regex_atom(<<"\\n", rest::binary>>, pos, state),
    do: {:ok, IR.literal("\n", span(pos)), rest, state}

  defp regex_atom(<<"\\r", rest::binary>>, pos, state),
    do: {:ok, IR.literal("\r", span(pos)), rest, state}

  defp regex_atom(<<"\\t", rest::binary>>, pos, state),
    do: {:ok, IR.literal("\t", span(pos)), rest, state}

  defp regex_atom(<<"\\", c::utf8, rest::binary>>, pos, state)
       when c in @regex_escape_literal_chars do
    {:ok, IR.literal(<<c::utf8>>, span(pos)), rest, state}
  end

  defp regex_atom(<<"\\", d, _::binary>>, _pos, _state) when d in ?1..?9 do
    {:error, "backreferences (\\#{<<d>>}) are not supported in /pattern/"}
  end

  defp regex_atom(<<"\\", _::binary>>, _pos, _state),
    do: {:error, "unrecognized escape in /pattern/"}

  defp regex_atom(<<"\\">>, _pos, _state), do: {:error, "unrecognized escape in /pattern/"}

  defp regex_atom(<<".", rest::binary>>, pos, state), do: {:ok, IR.any(span(pos)), rest, state}

  defp regex_atom(<<c, _::binary>>, _pos, _state) when c in [?*, ?+, ??, ?{, ?}] do
    {:error, "nothing to repeat in /pattern/"}
  end

  defp regex_atom(<<c::utf8, rest::binary>>, pos, state),
    do: {:ok, IR.literal(<<c::utf8>>, span(pos)), rest, state}

  defp regex_atom(<<>>, _pos, _state),
    do: {:error, "expected an atom in /pattern/, found end of pattern"}

  defp negated_ref(name, pos),
    do:
      IR.seq([IR.not_pred(IR.rule_ref(name, span(pos)), span(pos)), IR.any(span(pos))], span(pos))

  defp regex_char_class(<<"^", rest::binary>>), do: regex_char_class_items(rest, true, [])
  defp regex_char_class(rest), do: regex_char_class_items(rest, false, [])

  defp regex_char_class_items(<<"]", rest::binary>>, negate, items),
    do: {:ok, %{negate: negate, items: Enum.reverse(items)}, rest}

  defp regex_char_class_items(<<>>, _negate, _items),
    do: {:error, "unterminated character class in /pattern/"}

  defp regex_char_class_items(<<"[:", rest::binary>>, negate, items) do
    {name, rest2} = take_lower(rest, [])

    case {Map.fetch(@posix_names, name), rest2} do
      {{:ok, posix}, <<":]", rest3::binary>>} ->
        regex_char_class_items(rest3, negate, [{:posix, posix} | items])

      {:error, _} ->
        {:error, "unknown POSIX class \"[:#{name}:]\" in /pattern/"}

      _ ->
        {:error, "malformed POSIX class in /pattern/"}
    end
  end

  defp regex_char_class_items(rest, negate, items) do
    with {:ok, first, rest2} <- regex_class_atom(rest) do
      case rest2 do
        <<"-", after_dash::binary>> when after_dash != <<>> ->
          if String.starts_with?(after_dash, "]") do
            regex_char_class_items(rest2, negate, [{:char, first} | items])
          else
            with {:ok, last, rest3} <- regex_class_atom(after_dash) do
              regex_char_class_items(rest3, negate, [{:range, first, last} | items])
            end
          end

        _ ->
          regex_char_class_items(rest2, negate, [{:char, first} | items])
      end
    end
  end

  defp regex_class_atom(<<"\\", rest::binary>>), do: regex_decode_escape(rest)
  defp regex_class_atom(<<c::utf8, rest::binary>>), do: {:ok, c, rest}
  defp regex_class_atom(<<>>), do: {:error, "unterminated character class in /pattern/"}

  defp regex_decode_escape(<<"n", rest::binary>>), do: {:ok, ?\n, rest}
  defp regex_decode_escape(<<"r", rest::binary>>), do: {:ok, ?\r, rest}
  defp regex_decode_escape(<<"t", rest::binary>>), do: {:ok, ?\t, rest}

  defp regex_decode_escape(<<c::utf8, rest::binary>>) when c in @regex_escape_literal_chars,
    do: {:ok, c, rest}

  defp regex_decode_escape(_), do: {:error, "unrecognized escape in /pattern/ character class"}

  defp take_lower(<<c, rest::binary>>, acc) when c in ?a..?z, do: take_lower(rest, [c | acc])
  defp take_lower(rest, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}

  # ---- @skip/~ splicing -----------------------------------------------------
  # Under an active @skip, every rule's sequence elements (after the first)
  # get a `SPACE*`-equivalent auto-spliced in front of them, so grammar
  # authors don't have to write whitespace-tolerance into every single rule
  # by hand. `~name` suppresses that splicing before one specific element,
  # for the rare case where adjacency actually matters.

  defp build_sequence(terms, context, state) do
    case terms do
      [{ir, _}] ->
        {ir, state}

      _ ->
        if context == :rule and state.skip_mode != :none do
          splice_skip(terms, state)
        else
          {IR.seq(Enum.map(terms, fn {ir, _} -> ir end)), state}
        end
    end
  end

  defp splice_skip(terms, state) do
    skip_name = skip_token_name(state)
    skip_ref = IR.rule_ref(skip_name)

    {exprs, state} =
      terms
      |> Enum.with_index()
      |> Enum.reduce({[], state}, fn
        {{ir, _suppress}, 0}, {acc, state} ->
          {[ir | acc], state}

        {{ir, true}, _}, {acc, state} ->
          {[ir | acc], state}

        {{ir, false}, _}, {acc, state} ->
          state =
            if state.skip_mode == :default,
              do: mark_predefined_used(state, :SPACE, {0, 0}),
              else: state

          {[ir, IR.star(skip_ref) | acc], state}
      end)

    {IR.seq(Enum.reverse(exprs)), state}
  end

  defp skip_token_name(state) do
    case state.skip_mode do
      :default -> :SPACE
      {:custom, name} -> name
    end
  end

  # ---- finalize: resolve predefined tokens, assemble Aether.Grammar ---------

  defp finalize(state) do
    digit_ir = state.predefined_overrides[:DIGIT] || default_digit()
    alpha_ir = state.predefined_overrides[:ALPHA] || default_alpha()
    alnum_ir = state.predefined_overrides[:ALNUM] || IR.choice([digit_ir, alpha_ir])
    space_ir = state.predefined_overrides[:SPACE] || default_space()
    hex_ir = state.predefined_overrides[:HEX] || default_hex()

    tokens =
      state.tokens_defs
      |> Map.put(:DIGIT, digit_ir)
      |> Map.put(:ALPHA, alpha_ir)
      |> Map.put(:ALNUM, alnum_ir)
      |> Map.put(:SPACE, space_ir)
      |> Map.put(:HEX, hex_ir)

    non_overridden_predefined = Enum.reject(@predefined, &(state.predefined_overrides[&1] != nil))
    token_order = state.token_order ++ non_overridden_predefined

    skip =
      case state.skip_mode do
        :none -> nil
        :default -> :SPACE
        {:custom, name} -> name
      end

    grammar = %Aether.Grammar{
      name: state.name,
      root: state.root,
      skip: skip,
      case_insensitive: state.case_insensitive,
      tokens: tokens,
      token_order: token_order,
      anon_tokens: state.anon_tokens,
      rules: state.rules_defs,
      source: state.source,
      file: state.file
    }

    validate_grammar(state, grammar)
  end

  defp validate_grammar(state, grammar) do
    cond do
      not Map.has_key?(grammar.rules, grammar.root) ->
        {:error,
         err_at(
           state,
           state.root_pos || {1, 1},
           "@root names undefined rule #{inspect(grammar.root)}"
         )}

      grammar.skip != nil and not Map.has_key?(grammar.tokens, grammar.skip) ->
        {:error,
         err_at(
           state,
           state.skip_pos || {1, 1},
           "@skip names undefined token #{inspect(grammar.skip)}"
         )}

      true ->
        {:ok, grammar}
    end
  end
end
