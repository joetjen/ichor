defmodule Aether.Reader do
  @moduledoc """
  The pure-syntax half of Aether's front-end: turns `.aether` source (via
  `Aether.Lexer`) into a concrete syntax tree that's a faithful record of
  what was written -- every pragma, token, and rule definition, in file
  order -- with no desugaring and no cross-definition semantics applied.

  This is the same "Reader" role `Grammar.Native`'s generated `parse/1`
  (or any of the ABNF/BNF/EBNF/PEG importers' own `parse/1`) plays for a
  grammar's *input*: a bare recognizer producing a raw tree, nothing
  more. `Aether.Eval` is the matching "Eval" half -- it's what turns this
  CST into actual `Grammar.IR` (not to be confused with
  `Ichor.Actions.evaluate/5`, which evaluates *parsed input* through a
  grammar's own actions; this evaluates *grammar source* into IR).

  Owns: the token/rule reference split (`ALL_CAPS` names a token,
  `snake-case` names a rule), the full expression grammar (choice >
  sequence > term > postfix > primary), `~` markers, quantifier syntax,
  `@indent`/`@samecol`, and every check that only depends on local
  syntax (a token body referencing a rule, an inline character class
  outside a token, a name or pragma declared twice). Everything that
  depends on the *whole* grammar -- predefined-token override/use
  tracking, case-insensitivity resolution, char-class/regex desugaring,
  inline-literal promotion, `@skip` splicing -- is `Aether.Eval`'s job,
  not this module's.
  """

  alias Aether.{Lexer, Token}
  alias Ichor.Error

  @predefined [:DIGIT, :ALPHA, :ALNUM, :SPACE, :HEX]

  defmodule Grammar do
    @moduledoc """
    The CST `Aether.Reader.read/2` produces: grammar-wide pragmas plus
    every token/rule definition in file order, each body an
    `Aether.Reader.cst()` tree. `Aether.Eval.build/1` is the only
    consumer.
    """

    @type def_t ::
            {:token, atom(), Aether.Reader.cst(), Aether.Reader.pos()}
            | {:rule, atom(), Aether.Reader.cst(), Aether.Reader.pos()}
            | {:keywords, atom(), %{String.t() => atom()}, Aether.Reader.pos()}
            | {:refine, atom(), String.t(), String.t(), [atom()], Aether.Reader.pos()}

    @type t :: %__MODULE__{
            name: String.t(),
            root: atom(),
            root_pos: Aether.Reader.pos(),
            skip_mode: :none | :default | {:custom, atom()},
            skip_pos: Aether.Reader.pos() | nil,
            case_insensitive: boolean(),
            engine: :peg | :lr | :glr,
            defs: [def_t()],
            source: String.t(),
            file: String.t() | nil
          }

    defstruct [
      :name,
      :root,
      :root_pos,
      :skip_mode,
      :skip_pos,
      :case_insensitive,
      engine: :peg,
      defs: [],
      source: nil,
      file: nil
    ]
  end

  @typedoc "A `{line, column}` source position."
  @type pos :: {pos_integer(), pos_integer()}

  @typedoc """
  A raw expression node, mirroring exactly what was written -- no
  desugaring. Composite nodes (`:seq`/`:choice`/`:capture`/`:and_pred`/
  `:not_pred`/`:indent`) carry no position of their own (matching
  `Grammar.IR`'s own convention of falling back to a descendant's span);
  leaf and quantifier nodes do.
  """
  @type cst ::
          {:seq, [{cst(), suppress_skip :: boolean()}]}
          | {:choice, [cst()]}
          | {:capture, atom(), cst()}
          | {:and_pred, cst()}
          | {:not_pred, cst()}
          | {:indent, cst(), :indent | :samecol}
          | {:quant, cst(),
             :star | :plus | :opt | {:bound, non_neg_integer(), non_neg_integer() | :infinity},
             pos()}
          | {:literal, String.t(), Token.case_flag(), pos()}
          | {:char_class, boolean(), [Token.class_item()], pos()}
          | {:regex, String.t(), pos()}
          | {:dot, pos()}
          | {:ref, atom(), pos()}
          | {:native, String.t(), String.t(), [atom()], hint(), pos()}

  @typedoc """
  Author-supplied facts for a `@native(...)` node, standing in for what
  `Grammar.Analysis` would otherwise compute structurally -- `nil` means
  "not given, `Aether.Eval` applies its default." `:leading`, when given,
  is itself a list of declared-dependency rule names (never arbitrary
  rules outside that list -- `@native(...)`'s own argument list is the
  only thing this node can reference).
  """
  @type hint :: %{nullable: boolean() | nil, leading: [atom()] | nil}

  @doc "Reads `source` into an `Aether.Reader.Grammar` CST."
  @spec read(String.t(), String.t() | nil) :: {:ok, Grammar.t()} | {:error, Error.t()}
  def read(source, file \\ nil) do
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
      engine: :peg,
      seen_pragmas: MapSet.new(),
      declared_token_names: MapSet.new(),
      declared_rule_names: MapSet.new(),
      defs: []
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
  defp punct(:arrow), do: "->"
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
      :at_engine -> parse_engine_pragma(state)
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

  # `@engine peg | lr | glr` -- selects which backend family the compiled
  # grammar targets; defaults to `peg` (today's only behavior) when
  # omitted, so no existing `.aether` file is affected.
  defp parse_engine_pragma(state) do
    if MapSet.member?(state.seen_pragmas, :engine) do
      {:error, err(state, peek(state), "@engine may only be given once")}
    else
      state = advance(state)

      with {:ok, tok, state} <-
             expect(state, :lower_ident, "'peg', 'lr', or 'glr' after @engine"),
           {:ok, engine} <- parse_engine_name(state, tok) do
        state =
          state
          |> mark_pragma_seen(:engine)
          |> Map.put(:engine, engine)

        parse_optional_pragmas(state)
      end
    end
  end

  defp parse_engine_name(_state, %Token{value: "peg"}), do: {:ok, :peg}
  defp parse_engine_name(_state, %Token{value: "lr"}), do: {:ok, :lr}
  defp parse_engine_name(_state, %Token{value: "glr"}), do: {:ok, :glr}

  defp parse_engine_name(state, tok),
    do:
      {:error,
       err(state, tok, "unknown @engine #{inspect(tok.value)} -- expected 'peg', 'lr', or 'glr'")}

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

      :at_keywords ->
        with {:ok, state} <- parse_keywords_def(state), do: parse_definitions(state)

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
         {:ok, cst, state} <- parse_choice(state, :token),
         {:ok, state} <- register_token(state, name, cst, pos) do
      parse_optional_refine(state, name)
    end
  end

  # ---- @keywords BASE { "text" -> NAME, ... } -------------------------------
  # Sugar for the common table-lookup case of the same reclassification
  # mechanism `@refine(...)` is the general escape hatch for -- see
  # `Grammar.Lexer`.

  defp parse_keywords_def(state) do
    tok = peek(state)
    pos = {tok.line, tok.column}
    state = advance(state)

    with {:ok, base_tok, state} <- expect(state, :upper_ident, "a token name after @keywords"),
         {:ok, _lb, state} <-
           expect(state, :lbrace, "'{' after @keywords #{base_tok.value}"),
         {:ok, table, state} <- parse_keyword_entries(state, %{}) do
      base_name = String.to_atom(base_tok.value)
      {:ok, %{state | defs: [{:keywords, base_name, table, pos} | state.defs]}}
    end
  end

  defp parse_keyword_entries(state, acc) do
    with {:ok, text_tok, state} <-
           expect(state, :string, "a string literal in @keywords { ... }"),
         {:ok, _arrow, state} <-
           expect(state, :arrow, "'->' after #{inspect(text_tok.value.text)}"),
         {:ok, name_tok, state} <- expect(state, :upper_ident, "a token name after '->'") do
      acc = Map.put(acc, text_tok.value.text, String.to_atom(name_tok.value))

      case peek_type(state) do
        :comma -> parse_keyword_entries(advance(state), acc)
        :rbrace -> {:ok, acc, advance(state)}
        _ -> {:error, err(state, peek(state), "expected ',' or '}' in @keywords { ... }")}
      end
    end
  end

  # ---- @refine("Module", "function", POSSIBLE_NAME, ...) -------------------
  # A token-definition suffix (mirrors `@native(...)`'s own module/function
  # string-pair convention): reclassifies/validates a matched token via
  # hand-written Elixir code instead of a plain `@keywords` table. The
  # trailing token names declare every name the callback might reclassify
  # to, the same "state your dependencies so Analysis can check them" role
  # `@native(...)`'s own dependency list plays.

  defp parse_optional_refine(state, token_name) do
    case peek_type(state) do
      :at_refine ->
        tok = peek(state)
        pos = {tok.line, tok.column}
        state = advance(state)

        with {:ok, _lp, state} <- expect(state, :lparen, "'(' after @refine"),
             {:ok, mod_tok, state} <-
               expect(state, :string, "a module name string after '@refine('"),
             {:ok, _c1, state} <- expect(state, :comma, "',' after @refine's module name"),
             {:ok, fun_tok, state} <-
               expect(state, :string, "a function name string after the module name"),
             {:ok, possible, state} <- parse_refine_possible_names(state),
             {:ok, _rp, state} <- expect(state, :rparen, "')' to close @refine(...)") do
          refine_def =
            {:refine, token_name, mod_tok.value.text, fun_tok.value.text, possible, pos}

          {:ok, %{state | defs: [refine_def | state.defs]}}
        end

      _ ->
        {:ok, state}
    end
  end

  defp parse_refine_possible_names(state) do
    case peek_type(state) do
      :comma ->
        state = advance(state)

        with {:ok, name_tok, state} <- expect(state, :upper_ident, "a token name after ','"),
             {:ok, rest, state} <- parse_refine_possible_names(state) do
          {:ok, [String.to_atom(name_tok.value) | rest], state}
        end

      _ ->
        {:ok, [], state}
    end
  end

  defp parse_rule_def(state) do
    name_tok = peek(state)
    name = String.to_atom(name_tok.value)
    pos = {name_tok.line, name_tok.column}
    state = advance(state)

    with {:ok, _define, state} <-
           expect(state, :define, "':=' after rule name #{name_tok.value}"),
         {:ok, cst, state} <- parse_choice(state, :rule) do
      register_rule(state, name, cst, pos)
    end
  end

  # Predefined names (`DIGIT`/`ALPHA`/`ALNUM`/`SPACE`/`HEX`) never enter
  # `declared_token_names` and skip the ordinary duplicate check entirely
  # -- whether a predefined name may be (re)declared depends on whether
  # it's already been *used* elsewhere in the file, which only `Eval`
  # can know (uses can be implicit, via a POSIX class item, a regex
  # escape, or an auto-spliced default skip token). `Eval` owns that
  # whole check, including "declared more than once".
  defp register_token(state, name, cst, pos) do
    cond do
      name in @predefined ->
        {:ok, %{state | defs: [{:token, name, cst, pos} | state.defs]}}

      MapSet.member?(state.declared_token_names, name) ->
        {:error, err_at(state, pos, "token #{name} is already declared")}

      true ->
        {:ok,
         %{
           state
           | defs: [{:token, name, cst, pos} | state.defs],
             declared_token_names: MapSet.put(state.declared_token_names, name)
         }}
    end
  end

  defp register_rule(state, name, cst, pos) do
    if MapSet.member?(state.declared_rule_names, name) do
      {:error, err_at(state, pos, "rule #{name} is already declared")}
    else
      {:ok,
       %{
         state
         | defs: [{:rule, name, cst, pos} | state.defs],
           declared_rule_names: MapSet.put(state.declared_rule_names, name)
       }}
    end
  end

  # ---- expression grammar: choice > sequence > term > postfix > primary ----

  # choice := sequence (PIPE sequence)*
  defp parse_choice(state, context) do
    with {:ok, first, state} <- parse_sequence(state, context) do
      parse_choice_rest(state, context, [first])
    end
  end

  defp parse_choice_rest(state, context, acc) do
    case peek_type(state) do
      :pipe ->
        state = advance(state)

        with {:ok, next, state} <- parse_sequence(state, context) do
          parse_choice_rest(state, context, [next | acc])
        end

      _ ->
        case Enum.reverse(acc) do
          [one] -> {:ok, one, state}
          many -> {:ok, {:choice, many}, state}
        end
    end
  end

  # sequence := gap_marked_term+
  defp parse_sequence(state, context) do
    parse_sequence_terms(state, context, [])
  end

  defp parse_sequence_terms(state, context, acc) do
    if continues_sequence?(state) do
      with {:ok, suppress, cst, state} <- parse_gap_marked_term(state, context) do
        parse_sequence_terms(state, context, [{cst, suppress} | acc])
      end
    else
      case Enum.reverse(acc) do
        [] ->
          {:error,
           err(state, peek(state), "expected an expression, found #{describe(peek(state))}")}

        [{one, _suppress}] ->
          {:ok, one, state}

        terms ->
          {:ok, {:seq, terms}, state}
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
        :at_samecol,
        :at_native
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

  defp parse_gap_marked_term(state, context) do
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

            with {:ok, cst, state} <- parse_term(state, context) do
              case cst do
                {:ref, _name, _pos} ->
                  {:ok, true, cst, state}

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
        with {:ok, cst, state} <- parse_term(state, context) do
          {:ok, false, cst, state}
        end
    end
  end

  # term := (lower_ident COLON)? postfix
  defp parse_term(state, context) do
    case peek(state) do
      %Token{type: :lower_ident, value: name} ->
        case peek_at(state, 1) do
          %Token{type: :colon} ->
            state = state |> advance() |> advance()

            with {:ok, inner, state} <- parse_postfix(state, context) do
              {:ok, {:capture, String.to_atom(name), inner}, state}
            end

          _ ->
            parse_postfix(state, context)
        end

      _ ->
        parse_postfix(state, context)
    end
  end

  # postfix := (AMP | BANG)? primary quantifier?
  defp parse_postfix(state, context) do
    case peek_type(state) do
      :amp ->
        state = advance(state)

        with {:ok, inner, state} <- parse_primary(state, context) do
          {:ok, {:and_pred, inner}, state}
        end

      :bang ->
        state = advance(state)

        with {:ok, inner, state} <- parse_primary(state, context) do
          {:ok, {:not_pred, inner}, state}
        end

      _ ->
        with {:ok, inner, state} <- parse_primary(state, context) do
          parse_quantifier_suffix(inner, state)
        end
    end
  end

  # `X*`/`X+`/`X{n,m}` need the same skip-splicing as an explicit
  # sequence -- see `Aether.Eval`'s `wrap_repetition/3` for why. The CST
  # just records the literal quantifier written; expansion is Eval's job.
  defp parse_quantifier_suffix(cst, state) do
    tok = peek(state)
    pos = {tok.line, tok.column}

    case tok.type do
      :star -> {:ok, {:quant, cst, :star, pos}, advance(state)}
      :plus -> {:ok, {:quant, cst, :plus, pos}, advance(state)}
      :question -> {:ok, {:quant, cst, :opt, pos}, advance(state)}
      :lbrace -> parse_bound(cst, pos, advance(state))
      _ -> {:ok, cst, state}
    end
  end

  defp parse_bound(cst, pos, state) do
    with {:ok, min_tok, state} <- expect(state, :number, "a number after '{'") do
      case peek_type(state) do
        :rbrace ->
          {:ok, {:quant, cst, {:bound, min_tok.value, min_tok.value}, pos}, advance(state)}

        :comma ->
          state = advance(state)

          case peek_type(state) do
            :number ->
              max_tok = peek(state)
              state = advance(state)

              with {:ok, _rb, state} <-
                     expect(state, :rbrace, "'}' to close '{#{min_tok.value},#{max_tok.value}'") do
                {:ok, {:quant, cst, {:bound, min_tok.value, max_tok.value}, pos}, state}
              end

            :rbrace ->
              {:ok, {:quant, cst, {:bound, min_tok.value, :infinity}, pos}, advance(state)}

            _ ->
              {:error, err(state, peek(state), "expected a number or '}' in repetition bound")}
          end

        _ ->
          {:error, err(state, peek(state), "expected ',' or '}' in repetition bound")}
      end
    end
  end

  # primary: literal | char_class | regex | . | UPPER_IDENT | lower_ident | "(" choice ")" | @indent(...) | @samecol(...)
  defp parse_primary(state, context) do
    case peek(state) do
      %Token{type: :string, value: %{text: text, case: case_flag}, line: line, column: col} ->
        {:ok, {:literal, text, case_flag, {line, col}}, advance(state)}

      %Token{type: :char_class} = tok ->
        if context != :token do
          {:error,
           err(
             state,
             tok,
             "rules may not contain an inline character class -- give it a named TOKEN instead"
           )}
        else
          %{negate: negate, items: items} = tok.value
          {:ok, {:char_class, negate, items, {tok.line, tok.column}}, advance(state)}
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
          {:ok, {:regex, tok.value, {tok.line, tok.column}}, advance(state)}
        end

      %Token{type: :dot} = tok ->
        if context != :token do
          {:error,
           err(state, tok, "rules may not contain '.' directly -- give it a named TOKEN instead")}
        else
          {:ok, {:dot, {tok.line, tok.column}}, advance(state)}
        end

      %Token{type: :upper_ident, value: v, line: line, column: col} ->
        {:ok, {:ref, String.to_atom(v), {line, col}}, advance(state)}

      %Token{type: :lower_ident, value: v, line: line, column: col} = tok ->
        if context == :token do
          {:error,
           err(state, tok, "a token body may only reference other tokens, not rule #{inspect(v)}")}
        else
          {:ok, {:ref, String.to_atom(v), {line, col}}, advance(state)}
        end

      %Token{type: :lparen} ->
        state = advance(state)

        with {:ok, inner, state} <- parse_choice(state, context),
             {:ok, _rp, state} <- expect(state, :rparen, "')' to close '('") do
          {:ok, inner, state}
        end

      %Token{type: :at_indent} = tok ->
        parse_indent_like(state, tok, context, :indent)

      %Token{type: :at_samecol} = tok ->
        parse_indent_like(state, tok, context, :samecol)

      %Token{type: :at_native} = tok ->
        parse_native(state, tok, context)

      tok ->
        {:error, err(state, tok, "expected an expression, found #{describe(tok)}")}
    end
  end

  # ---- @native("Module", "function", dep, ...) @hint(...) -------------------
  # `context` (`:rule` or `:token`) only matters for `@hint`'s `leading:`
  # entry below -- everything else about `@native(...)`'s own syntax is
  # identical either way; `Aether.Eval` is what actually builds a
  # `Grammar.IR.Custom` or `Grammar.IR.CustomLexeme` depending on it.

  defp parse_native(state, tok, context) do
    pos = {tok.line, tok.column}
    state = advance(state)

    with {:ok, _lp, state} <- expect(state, :lparen, "'(' after @native"),
         {:ok, mod_tok, state} <-
           expect(state, :string, "a module name string after '@native('"),
         {:ok, _c1, state} <- expect(state, :comma, "',' after @native's module name"),
         {:ok, fun_tok, state} <-
           expect(state, :string, "a function name string after the module name"),
         {:ok, deps, state} <- parse_native_deps(state),
         {:ok, _rp, state} <- expect(state, :rparen, "')' to close @native(...)") do
      parse_optional_hint(state, mod_tok.value.text, fun_tok.value.text, deps, pos, context)
    end
  end

  defp parse_native_deps(state) do
    case peek_type(state) do
      :comma ->
        state = advance(state)

        with {:ok, dep_tok, state} <- expect(state, :lower_ident, "a rule name after ','"),
             {:ok, rest, state} <- parse_native_deps(state) do
          {:ok, [String.to_atom(dep_tok.value) | rest], state}
        end

      _ ->
        {:ok, [], state}
    end
  end

  defp parse_optional_hint(state, mod_str, fun_str, deps, pos, context) do
    case peek_type(state) do
      :at_hint ->
        state = advance(state)

        with {:ok, _lp, state} <- expect(state, :lparen, "'(' after @hint"),
             {:ok, hint, state} <-
               parse_hint_entries(state, deps, context, %{nullable: nil, leading: nil}),
             {:ok, _rp, state} <- expect(state, :rparen, "')' to close @hint(...)") do
          {:ok, {:native, mod_str, fun_str, deps, hint, pos}, state}
        end

      _ ->
        {:ok, {:native, mod_str, fun_str, deps, %{nullable: nil, leading: nil}, pos}, state}
    end
  end

  defp parse_hint_entries(state, deps, context, acc) do
    with {:ok, acc, state} <- parse_hint_entry(state, deps, context, acc) do
      case peek_type(state) do
        :comma -> parse_hint_entries(advance(state), deps, context, acc)
        _ -> {:ok, acc, state}
      end
    end
  end

  defp parse_hint_entry(state, deps, context, acc) do
    case peek(state) do
      %Token{type: :lower_ident, value: "nullable"} ->
        state = advance(state)

        with {:ok, _c, state} <- expect(state, :colon, "':' after 'nullable'"),
             {:ok, value, state} <- parse_bool(state) do
          {:ok, %{acc | nullable: value}, state}
        end

      %Token{type: :lower_ident, value: "leading"} = tok when context != :rule ->
        {:error,
         err(
           state,
           tok,
           "leading: is only meaningful for a rule-position @native(...) -- left-recursion-cycle detection doesn't apply to tokens"
         )}

      %Token{type: :lower_ident, value: "leading"} ->
        state = advance(state)

        with {:ok, _c, state} <- expect(state, :colon, "':' after 'leading'"),
             {:ok, names, state} <- parse_leading_list(state, deps) do
          {:ok, %{acc | leading: names}, state}
        end

      tok ->
        {:error, err(state, tok, "expected 'nullable' or 'leading' in @hint(...)")}
    end
  end

  defp parse_bool(state) do
    case peek(state) do
      %Token{type: :lower_ident, value: "true"} -> {:ok, true, advance(state)}
      %Token{type: :lower_ident, value: "false"} -> {:ok, false, advance(state)}
      tok -> {:error, err(state, tok, "expected 'true' or 'false'")}
    end
  end

  defp parse_leading_list(state, deps) do
    with {:ok, _lp, state} <- expect(state, :lparen, "'(' after 'leading:'") do
      case peek_type(state) do
        :rparen ->
          {:ok, [], advance(state)}

        _ ->
          with {:ok, names, state} <- parse_leading_names(state, deps),
               {:ok, _rp, state} <- expect(state, :rparen, "')' to close 'leading: (...)'") do
            {:ok, names, state}
          end
      end
    end
  end

  defp parse_leading_names(state, deps) do
    with {:ok, tok, state} <- expect(state, :lower_ident, "a rule name in 'leading: (...)'"),
         {:ok, name} <- validate_leading_name(state, tok, deps) do
      case peek_type(state) do
        :comma ->
          with {:ok, rest, state} <- parse_leading_names(advance(state), deps) do
            {:ok, [name | rest], state}
          end

        _ ->
          {:ok, [name], state}
      end
    end
  end

  defp validate_leading_name(state, tok, deps) do
    name = String.to_atom(tok.value)

    if name in deps do
      {:ok, name}
    else
      {:error,
       err(
         state,
         tok,
         "@hint's leading: may only name a rule already listed as an @native(...) dependency (#{inspect(name)} isn't one of #{inspect(deps)})"
       )}
    end
  end

  # `@indent(expr)`/`@samecol(expr)`. Also accepts a bare single term with
  # no parens (`@samecol pair`) as sugar for wrapping just that one term.
  defp parse_indent_like(state, tok, context, kind) do
    if context != :rule do
      {:error, err(state, tok, "@#{kind} is only valid in rule bodies")}
    else
      state = advance(state)

      case peek_type(state) do
        :lparen ->
          state = advance(state)

          with {:ok, inner, state} <- parse_choice(state, :rule),
               {:ok, _rp, state} <- expect(state, :rparen, "')' to close @#{kind}(...)") do
            {:ok, {:indent, inner, kind}, state}
          end

        _ ->
          with {:ok, inner, state} <- parse_postfix(state, context) do
            {:ok, {:indent, inner, kind}, state}
          end
      end
    end
  end

  # ---- finalize: assemble the CST grammar ------------------------------

  defp finalize(state) do
    skip_mode =
      case state.skip_mode do
        :none -> :none
        :default -> :default
        {:custom, name} -> {:custom, name}
      end

    {:ok,
     %Grammar{
       name: state.name,
       root: state.root,
       root_pos: state.root_pos,
       skip_mode: skip_mode,
       skip_pos: state.skip_pos,
       case_insensitive: state.case_insensitive,
       engine: state.engine,
       defs: Enum.reverse(state.defs),
       source: state.source,
       file: state.file
     }}
  end
end
