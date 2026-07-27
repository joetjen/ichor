defmodule Aether.Eval do
  @moduledoc """
  The semantic half of Aether's front-end: turns an `Aether.Reader.Grammar`
  CST into a fully resolved `Aether.Grammar`, with every body already
  `Grammar.IR`.

  (Not to be confused with `Ichor.Actions.evaluate/5`, which evaluates
  *parsed input* through a grammar's own actions -- this evaluates
  *grammar source*, already read into a CST by `Aether.Reader`, into
  `Grammar.IR`.)

  Owns everything that needs more than one definition's worth of
  context: predefined-token (`DIGIT`/`ALPHA`/`ALNUM`/`SPACE`/`HEX`)
  override-before-use tracking (uses can be implicit -- a POSIX class
  item, a regex escape, an auto-spliced default skip token -- which is
  exactly why this can't be checked while merely reading syntax),
  case-insensitivity resolution, character-class/regex desugaring,
  inline-literal auto-promotion to anonymous tokens, `@skip` splicing,
  and the final `@root`/`@skip` validation.
  """

  alias Aether.Reader
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

  @doc "Builds a fully resolved `Aether.Grammar` from `reader_grammar`."
  @spec build(Reader.Grammar.t()) :: {:ok, Aether.Grammar.t()} | {:error, Error.t()}
  def build(%Reader.Grammar{} = rg) do
    state = rg |> new_state() |> mark_initial_skip_use(rg)

    case process_defs(rg.defs, state) do
      {:ok, state} -> finalize(rg, state)
      {:error, _} = err -> err
    end
  end

  # ---- state ----------------------------------------------------------------

  defp new_state(rg) do
    %{
      source: rg.source,
      file: rg.file,
      case_insensitive: rg.case_insensitive,
      skip_mode: rg.skip_mode,
      predefined_overrides: Map.new(@predefined, &{&1, nil}),
      predefined_used_at: Map.new(@predefined, &{&1, nil}),
      tokens: %{},
      token_order: [],
      rules: %{},
      anon_by_key: %{},
      anon_counter: 0,
      anon_tokens: MapSet.new()
    }
  end

  # The `@skip CUSTOM` pragma is itself a reference to `CUSTOM` -- if
  # that happens to be one of the predefined names, it counts as "used"
  # from the moment the pragma is read, same as it did back when this was
  # all one pass over the token stream.
  defp mark_initial_skip_use(state, %Reader.Grammar{skip_mode: {:custom, name}, skip_pos: pos}),
    do: mark_predefined_used(state, name, pos)

  defp mark_initial_skip_use(state, %Reader.Grammar{}), do: state

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

  defp span({line, col}), do: %IR.Meta{source_span: {line, col, 0}}

  # ---- definitions, in file order ----------------------------------------

  defp process_defs(defs, state) do
    Enum.reduce_while(defs, {:ok, state}, fn
      {:token, name, cst, pos}, {:ok, state} ->
        with {:ok, ir, state} <- convert(cst, :token, state),
             {:ok, state} <- register_token(state, name, ir, pos) do
          {:cont, {:ok, state}}
        else
          {:error, _} = err -> {:halt, err}
        end

      {:rule, name, cst, _pos}, {:ok, state} ->
        case convert(cst, :rule, state) do
          {:ok, ir, state} -> {:cont, {:ok, register_rule(state, name, ir)}}
          {:error, _} = err -> {:halt, err}
        end
    end)
  end

  # Predefined names never went into `Aether.Reader`'s ordinary
  # duplicate-name check -- whether one may be (re)declared depends on
  # whether it's already been *used* somewhere in the file, which is
  # exactly this module's job to know.
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

      true ->
        {:ok,
         %{
           state
           | tokens: Map.put(state.tokens, name, ir),
             token_order: state.token_order ++ [name]
         }}
    end
  end

  defp register_rule(state, name, ir), do: %{state | rules: Map.put(state.rules, name, ir)}

  # ---- predefined-token override/use bookkeeping ---------------------------

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

  # ---- CST -> Grammar.IR ---------------------------------------------------

  @spec convert(Reader.cst(), :token | :rule, map()) ::
          {:ok, IR.expr(), map()} | {:error, Error.t()}
  defp convert({:literal, text, case_flag, pos}, context, state) do
    insensitive = effective_case_insensitive?(state, case_flag)
    ir = desugar_literal(text, insensitive, pos)

    case context do
      :token -> {:ok, ir, state}
      :rule -> promote_inline_literal(state, ir, text, insensitive, pos)
    end
  end

  defp convert({:char_class, negate, items, pos}, _context, state) do
    desugar_char_class(%{negate: negate, items: items}, pos, state)
  end

  defp convert({:regex, pattern, pos}, _context, state) do
    desugar_regex(pattern, pos, state)
  end

  defp convert({:dot, pos}, _context, state), do: {:ok, IR.any(span(pos)), state}

  defp convert({:ref, name, pos}, _context, state) do
    state = mark_predefined_used(state, name, pos)
    {:ok, IR.rule_ref(name, span(pos)), state}
  end

  defp convert({:capture, name, inner}, context, state) do
    with {:ok, inner_ir, state} <- convert(inner, context, state) do
      {:ok, IR.capture(name, inner_ir), state}
    end
  end

  defp convert({:and_pred, inner}, context, state) do
    with {:ok, inner_ir, state} <- convert(inner, context, state) do
      {:ok, IR.and_pred(inner_ir), state}
    end
  end

  defp convert({:not_pred, inner}, context, state) do
    with {:ok, inner_ir, state} <- convert(inner, context, state) do
      {:ok, IR.not_pred(inner_ir), state}
    end
  end

  defp convert({:indent, inner, kind}, context, state) do
    with {:ok, inner_ir, state} <- convert(inner, context, state) do
      {:ok, IR.indent(inner_ir, kind), state}
    end
  end

  defp convert({:quant, inner, :opt, pos}, context, state) do
    with {:ok, inner_ir, state} <- convert(inner, context, state) do
      {:ok, IR.opt(inner_ir, span(pos)), state}
    end
  end

  defp convert({:quant, inner, :star, pos}, context, state) do
    with {:ok, inner_ir, state} <- convert(inner, context, state) do
      {ir2, state} = wrap_repetition(inner_ir, context, state, pos, 0, :infinity)
      {:ok, ir2, state}
    end
  end

  defp convert({:quant, inner, :plus, pos}, context, state) do
    with {:ok, inner_ir, state} <- convert(inner, context, state) do
      {ir2, state} = wrap_repetition(inner_ir, context, state, pos, 1, :infinity)
      {:ok, ir2, state}
    end
  end

  defp convert({:quant, inner, {:bound, min, max}, pos}, context, state) do
    with {:ok, inner_ir, state} <- convert(inner, context, state) do
      {ir2, state} = wrap_repetition(inner_ir, context, state, pos, min, max)
      {:ok, ir2, state}
    end
  end

  defp convert({:choice, alts}, context, state) do
    with {:ok, irs, state} <- convert_list(alts, context, state) do
      {:ok, IR.choice(irs), state}
    end
  end

  defp convert({:seq, terms}, context, state) do
    with {:ok, ir_pairs, state} <- convert_seq_terms(terms, context, state) do
      {ir, state} = build_sequence(ir_pairs, context, state)
      {:ok, ir, state}
    end
  end

  defp convert_list(csts, context, state) do
    Enum.reduce_while(csts, {:ok, [], state}, fn cst, {:ok, acc, state} ->
      case convert(cst, context, state) do
        {:ok, ir, state} -> {:cont, {:ok, [ir | acc], state}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc, state} -> {:ok, Enum.reverse(acc), state}
      {:error, _} = err -> err
    end
  end

  defp convert_seq_terms(terms, context, state) do
    Enum.reduce_while(terms, {:ok, [], state}, fn {cst, suppress}, {:ok, acc, state} ->
      case convert(cst, context, state) do
        {:ok, ir, state} -> {:cont, {:ok, [{ir, suppress} | acc], state}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc, state} -> {:ok, Enum.reverse(acc), state}
      {:error, _} = err -> err
    end
  end

  # Splicing itself can never fail (every term is already converted IR by
  # this point), so this returns a plain `{ir, state}` rather than the
  # `{:ok, ir, state}` shape `convert/3` and its callers use.
  defp build_sequence(ir_pairs, context, state) do
    case ir_pairs do
      [{ir, _}] ->
        {ir, state}

      _ ->
        if context == :rule and state.skip_mode != :none do
          splice_skip(ir_pairs, state)
        else
          {IR.seq(Enum.map(ir_pairs, fn {ir, _} -> ir end)), state}
        end
    end
  end

  defp splice_skip(ir_pairs, state) do
    skip_name = skip_token_name(state)
    skip_ref = IR.rule_ref(skip_name)

    {exprs, state} =
      ir_pairs
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

  defp skip_splicing?(context, state), do: context == :rule and state.skip_mode != :none

  defp skip_token_name(state) do
    case state.skip_mode do
      :default -> :SPACE
      {:custom, name} -> name
    end
  end

  defp skip_ref(state, pos) do
    name = skip_token_name(state)

    state =
      if state.skip_mode == :default,
        do: mark_predefined_used(state, :SPACE, pos),
        else: state

    {IR.rule_ref(name), state}
  end

  # `ir{min,max}`, skip-separated: `ir`, then `min - 1` more mandatory
  # skip-preceded copies, then up to `max - min` further optional ones
  # (unbounded, for `max == :infinity`). When `min == 0`, the very first
  # `ir` is itself optional, so the whole thing is wrapped in one more
  # `Opt` -- everything after it already carries its own leading skip, so
  # nesting it inside that `Opt` doesn't change what it means.
  defp wrap_repetition(ir, context, state, pos, min, max) do
    if skip_splicing?(context, state) and {min, max} != {0, 0} do
      {skip_ref_ir, state} = skip_ref(state, pos)
      unit = IR.seq([IR.star(skip_ref_ir), ir])

      extra_min = max(min - 1, 0)
      extra_max = if max == :infinity, do: :infinity, else: max - 1

      extra =
        if {extra_min, extra_max} == {0, 0},
          do: [],
          else: [IR.rep(unit, extra_min, extra_max, span(pos))]

      body = IR.seq([ir | extra])
      ir2 = if min == 0, do: IR.opt(body, span(pos)), else: body
      {ir2, state}
    else
      {bare_repetition(ir, min, max, span(pos)), state}
    end
  end

  defp bare_repetition(ir, 0, :infinity, meta), do: IR.star(ir, meta)
  defp bare_repetition(ir, 1, :infinity, meta), do: IR.plus(ir, meta)
  defp bare_repetition(ir, min, max, meta), do: IR.rep(ir, min, max, meta)

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
            tokens: Map.put(state.tokens, name, ir),
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

    if Map.has_key?(state.tokens, name) do
      fresh_anon_name(state)
    else
      {name, state}
    end
  end

  # ---- literal case-insensitivity desugaring ---------------------------------

  defp effective_case_insensitive?(_state, :insensitive), do: true
  defp effective_case_insensitive?(_state, :sensitive), do: false
  defp effective_case_insensitive?(state, :default), do: state.case_insensitive

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

  # ---- finalize: resolve predefined tokens, assemble Aether.Grammar ---------

  defp finalize(rg, state) do
    digit_ir = state.predefined_overrides[:DIGIT] || default_digit()
    alpha_ir = state.predefined_overrides[:ALPHA] || default_alpha()
    alnum_ir = state.predefined_overrides[:ALNUM] || IR.choice([digit_ir, alpha_ir])
    space_ir = state.predefined_overrides[:SPACE] || default_space()
    hex_ir = state.predefined_overrides[:HEX] || default_hex()

    tokens =
      state.tokens
      |> Map.put(:DIGIT, digit_ir)
      |> Map.put(:ALPHA, alpha_ir)
      |> Map.put(:ALNUM, alnum_ir)
      |> Map.put(:SPACE, space_ir)
      |> Map.put(:HEX, hex_ir)

    non_overridden_predefined = Enum.reject(@predefined, &(state.predefined_overrides[&1] != nil))
    token_order = state.token_order ++ non_overridden_predefined

    skip =
      case rg.skip_mode do
        :none -> nil
        :default -> :SPACE
        {:custom, name} -> name
      end

    grammar = %Aether.Grammar{
      name: rg.name,
      root: rg.root,
      skip: skip,
      case_insensitive: rg.case_insensitive,
      tokens: tokens,
      token_order: token_order,
      anon_tokens: state.anon_tokens,
      rules: state.rules,
      source: rg.source,
      file: rg.file
    }

    validate_grammar(rg, grammar)
  end

  defp validate_grammar(rg, grammar) do
    cond do
      not Map.has_key?(grammar.rules, grammar.root) ->
        {:error,
         err_at(
           rg,
           rg.root_pos || {1, 1},
           "@root names undefined rule #{inspect(grammar.root)}"
         )}

      grammar.skip != nil and not Map.has_key?(grammar.tokens, grammar.skip) ->
        {:error,
         err_at(
           rg,
           rg.skip_pos || {1, 1},
           "@skip names undefined token #{inspect(grammar.skip)}"
         )}

      true ->
        {:ok, grammar}
    end
  end
end
