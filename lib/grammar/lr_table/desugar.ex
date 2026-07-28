defmodule Grammar.LRTable.Desugar do
  @moduledoc """
  Flattens `grammar.rules`' PEG-shaped IR into the flat CFG production
  list `Grammar.LRTable.Production` describes, for `Grammar.LRTable`'s
  LR(0)/SLR(1) construction to consume.

  The one representational mismatch this exists to bridge: a CFG
  production's right-hand side is a flat sequence of single symbols,
  while PEG's IR is a tree (`Seq`/`Choice`/`Star`/`Plus`/`Opt`/`Rep` can
  all nest arbitrarily). Only a `RuleRef` (a reference to an actual
  declared token or rule) is already a single symbol; everything else
  gets a fresh compiler-generated helper nonterminal (`$star_1`,
  `$opt_2`, ...) standing in for it -- an artifact of the CFG
  representation that doesn't exist in the original grammar at all.

  `:splice`-kind captures (see `Grammar.LRTable.Production`) are what
  erase that artifact again at reduce time: a helper nonterminal's own
  already-built captures map gets merged directly into its parent's,
  so the final raw-capture tree looks exactly like what
  `Grammar.VM`/`Grammar.Native` would have built for the same grammar --
  the boundary a helper nonterminal introduces is purely structural
  (needed so the LR table has single symbols to work with), never
  semantic.

  Reuses the exact same token/rule classification and implicit-capture
  exclusion rules every other backend uses (`Grammar.VM.RuleCompiler`'s
  own `token_names/1`/`implicit_capture_exclusions/1`) so a
  `@keywords`/`@refine` target name, an anonymous auto-promoted literal
  token, or the grammar's own spliced `@skip` token are all treated
  identically here -- in particular, a spliced `@skip` token (already an
  ordinary, uncaptured `Star[RuleRef(skip)]` node in the IR by the time
  this runs -- see `Aether.Eval`'s own `splice_skip/2`) needs no special
  handling at all: it desugars into an ordinary `:splice`-kind helper
  nonterminal whose own body has no capture entries, so splicing its
  empty map into the parent is simply a no-op.
  """

  alias Grammar.IR
  alias Grammar.LRTable.Production
  alias Ichor.Error

  @start_symbol :"$start"
  @end_symbol :"$end"

  @doc "The augmented start nonterminal every desugared grammar's automaton is built from."
  @spec start_symbol() :: atom()
  def start_symbol, do: @start_symbol

  @doc "The synthetic end-of-input terminal appended by `Grammar.LRTable`'s automaton construction."
  @spec end_symbol() :: atom()
  def end_symbol, do: @end_symbol

  @doc """
  Desugars `grammar.rules` (plus a fresh `$start := root` production) into
  a flat production list, or every unsupported-construct error found.
  """
  @spec run(Aether.Grammar.t()) :: {:ok, [Production.t()]} | {:error, [Error.t()]}
  def run(%Aether.Grammar{} = grammar) do
    state = %{
      grammar: grammar,
      token_names: Grammar.VM.RuleCompiler.token_names(grammar),
      excluded: Grammar.VM.RuleCompiler.implicit_capture_exclusions(grammar),
      productions: [],
      next_id: 0,
      helper_counter: 0,
      errors: []
    }

    state =
      add_production(state, @start_symbol, [{:nonterminal, grammar.root}], [{0, nil, :splice}])

    state =
      Enum.reduce(grammar.rule_order, state, fn name, state ->
        desugar_group_body(name, Map.fetch!(grammar.rules, name), false, state)
      end)

    case Enum.reverse(state.errors) do
      [] -> {:ok, Enum.reverse(state.productions)}
      errors -> {:error, errors}
    end
  end

  # ---- production bookkeeping --------------------------------------------

  defp add_production(state, lhs, rhs, captures) do
    production = %Production{id: state.next_id, lhs: lhs, rhs: rhs, captures: captures}
    %{state | productions: [production | state.productions], next_id: state.next_id + 1}
  end

  defp fresh_helper(kind, state) do
    n = state.helper_counter + 1
    name = String.to_atom("$#{kind}_#{n}")
    {name, %{state | helper_counter: n}}
  end

  defp add_error(state, ir, what) do
    {line, col} = position_of(ir)

    error =
      Error.new(
        message: "#{what} is not supported in an @engine lr/glr rule",
        stage: :analysis,
        file: state.grammar.file,
        line: line,
        column: col,
        source: state.grammar.source
      )

    %{state | errors: [error | state.errors]}
  end

  defp position_of(%{meta: %IR.Meta{source_span: {line, col, _len}}}), do: {line, col}
  defp position_of(_), do: {nil, nil}

  # ---- grammar shape helpers ----------------------------------------------

  defp choice_alternatives(%IR.Choice{exprs: exprs}), do: exprs
  defp choice_alternatives(other), do: [other]

  defp seq_elements(%IR.Seq{exprs: exprs}), do: exprs
  defp seq_elements(other), do: [other]

  defp symbol_for(name, state) do
    if MapSet.member?(state.token_names, name), do: {:terminal, name}, else: {:nonterminal, name}
  end

  defp kind_for(name, state) do
    if MapSet.member?(state.token_names, name), do: :token, else: :rule
  end

  defp shift_index({idx, name, kind}, by), do: {idx + by, name, kind}
  defp shift_all(captures, by), do: Enum.map(captures, &shift_index(&1, by))

  # ---- a rule/helper's own alternatives -> one production each -----------

  defp desugar_group_body(lhs, ir, discard?, state) do
    Enum.reduce(choice_alternatives(ir), state, &desugar_alternative(lhs, &1, discard?, &2))
  end

  defp desugar_alternative(lhs, alt_ir, discard?, state) do
    {rhs, captures, state} = desugar_elements(seq_elements(alt_ir), discard?, state)
    add_production(state, lhs, rhs, captures)
  end

  defp desugar_elements(elements, discard?, state) do
    {rev_rhs, rev_captures, _index, state} =
      Enum.reduce(elements, {[], [], 0, state}, fn el, {rhs_acc, cap_acc, idx, state} ->
        {symbol, capture, state} = desugar_element(el, discard?, state)
        cap_acc = if capture, do: [shift_index(capture, idx) | cap_acc], else: cap_acc
        {[symbol | rhs_acc], cap_acc, idx + 1, state}
      end)

    {Enum.reverse(rev_rhs), Enum.reverse(rev_captures), state}
  end

  # ---- one grammar term -> one RHS symbol (+ optional capture entry) -----

  # A bare (implicitly self-captured) or explicitly-captured direct
  # `RuleRef` never needs a helper nonterminal -- it's already a single
  # symbol. Everything else does, since a CFG production's RHS can only
  # ever be a flat list of single symbols.
  defp desugar_element(%IR.RuleRef{name: ref_name}, discard?, state) do
    symbol = symbol_for(ref_name, state)

    capture =
      if discard? or MapSet.member?(state.excluded, ref_name),
        do: nil,
        else: {0, ref_name, kind_for(ref_name, state)}

    {symbol, capture, state}
  end

  defp desugar_element(
         %IR.Capture{name: cap_name, expr: %IR.RuleRef{name: ref_name}},
         discard?,
         state
       ) do
    symbol = symbol_for(ref_name, state)
    capture = if discard?, do: nil, else: {0, cap_name, kind_for(ref_name, state)}
    {symbol, capture, state}
  end

  # A captured *composite* (anything else): `RuleCompiler.leaf/4`'s own
  # unconditional fallback for this shape is a span-based `:text` capture,
  # discarding whatever's inside -- mirrored exactly here, so the helper's
  # own internal captures are never even built (discard_inner? always true).
  defp desugar_element(%IR.Capture{name: cap_name, expr: inner}, discard?, state) do
    {helper, state} = fresh_helper(:grp, state)
    state = desugar_group_body(helper, inner, true, state)
    capture = if discard?, do: nil, else: {0, cap_name, :text}
    {{:nonterminal, helper}, capture, state}
  end

  # An uncaptured bare group (parenthesized `(a b)`, or an inner `Seq`/
  # `Choice` produced by Aether's own front-end) -- its inner captures
  # still surface into the enclosing rule directly, exactly as they would
  # without the parens, so this is `:splice`-kind, not `:text`.
  defp desugar_element(%IR.Seq{} = ir, discard?, state) do
    {helper, state} = fresh_helper(:grp, state)
    state = desugar_group_body(helper, ir, discard?, state)
    capture = if discard?, do: nil, else: {0, nil, :splice}
    {{:nonterminal, helper}, capture, state}
  end

  defp desugar_element(%IR.Choice{} = ir, discard?, state) do
    {helper, state} = fresh_helper(:grp, state)
    state = desugar_group_body(helper, ir, discard?, state)
    capture = if discard?, do: nil, else: {0, nil, :splice}
    {{:nonterminal, helper}, capture, state}
  end

  defp desugar_element(%IR.Star{expr: e}, discard?, state) do
    {helper, state} = desugar_star(e, discard?, state)
    capture = if discard?, do: nil, else: {0, nil, :splice}
    {{:nonterminal, helper}, capture, state}
  end

  defp desugar_element(%IR.Plus{expr: e}, discard?, state) do
    {helper, state} = desugar_plus(e, discard?, state)
    capture = if discard?, do: nil, else: {0, nil, :splice}
    {{:nonterminal, helper}, capture, state}
  end

  defp desugar_element(%IR.Opt{expr: e}, discard?, state) do
    {helper, state} = desugar_opt(e, discard?, state)
    capture = if discard?, do: nil, else: {0, nil, :splice}
    {{:nonterminal, helper}, capture, state}
  end

  defp desugar_element(%IR.Rep{expr: e, min: min, max: max}, discard?, state) do
    {rhs, captures, state} = desugar_rep_body(e, min, max, discard?, state)
    {helper, state} = fresh_helper(:rep, state)
    state = add_production(state, helper, rhs, captures)
    capture = if discard?, do: nil, else: {0, nil, :splice}
    {{:nonterminal, helper}, capture, state}
  end

  defp desugar_element(%IR.AndPred{} = ir, _discard?, state),
    do: {{:terminal, :"$error"}, nil, add_error(state, ir, "&predicate (lookahead)")}

  defp desugar_element(%IR.NotPred{} = ir, _discard?, state),
    do: {{:terminal, :"$error"}, nil, add_error(state, ir, "!predicate (negative lookahead)")}

  defp desugar_element(%IR.Indent{} = ir, _discard?, state),
    do: {{:terminal, :"$error"}, nil, add_error(state, ir, "@indent/@samecol")}

  defp desugar_element(%IR.Custom{} = ir, _discard?, state),
    do: {{:terminal, :"$error"}, nil, add_error(state, ir, "rule-position @native(...)")}

  # ---- Star/Plus/Opt/Rep -> left-recursive helper nonterminals -----------
  # Left-recursive, not right-recursive: bottom-up shift-reduce parsing
  # handles left recursion natively and efficiently (unlike top-down
  # recursive descent, which is exactly why the PEG backends can't do
  # this), so there's no reason to prefer the right-recursive shape a PEG
  # engine would need.

  defp desugar_star(body_ir, discard?, state) do
    {helper, state} = fresh_helper(:star, state)
    state = add_production(state, helper, [], [])

    {body_rhs, body_captures, state} = desugar_elements(seq_elements(body_ir), discard?, state)
    rhs = [{:nonterminal, helper} | body_rhs]
    captures = [{0, nil, :splice} | shift_all(body_captures, 1)]
    state = add_production(state, helper, rhs, captures)

    {helper, state}
  end

  defp desugar_plus(body_ir, discard?, state) do
    {helper, state} = fresh_helper(:plus, state)

    {base_rhs, base_captures, state} = desugar_elements(seq_elements(body_ir), discard?, state)
    state = add_production(state, helper, base_rhs, base_captures)

    {rec_rhs, rec_captures, state} = desugar_elements(seq_elements(body_ir), discard?, state)
    rhs = [{:nonterminal, helper} | rec_rhs]
    captures = [{0, nil, :splice} | shift_all(rec_captures, 1)]
    state = add_production(state, helper, rhs, captures)

    {helper, state}
  end

  defp desugar_opt(body_ir, discard?, state) do
    {helper, state} = fresh_helper(:opt, state)
    state = add_production(state, helper, [], [])

    {body_rhs, body_captures, state} = desugar_elements(seq_elements(body_ir), discard?, state)
    state = add_production(state, helper, body_rhs, body_captures)

    {helper, state}
  end

  # `min` mandatory copies (inlined directly -- a repeated capture name
  # across several ordinary RHS positions in the *same* production
  # already list-accumulates via plain `merge_capture` at reduce time,
  # same as it would across several `:cap_end`s in one PEG frame, so no
  # helper nonterminal is needed just for the mandatory copies) plus
  # either an unbounded `Star`-style tail (`max: :infinity`) or a bounded
  # chain of optional trailing copies, each spliced in.
  defp desugar_rep_body(body_ir, min, :infinity, discard?, state) do
    {mand_rhs, mand_captures, state} = desugar_repeated(body_ir, min, discard?, state)
    {star_helper, state} = desugar_star(body_ir, discard?, state)
    rhs = mand_rhs ++ [{:nonterminal, star_helper}]
    tail = if discard?, do: [], else: [{length(mand_rhs), nil, :splice}]
    {rhs, mand_captures ++ tail, state}
  end

  defp desugar_rep_body(body_ir, min, max, discard?, state) when max == min do
    desugar_repeated(body_ir, min, discard?, state)
  end

  defp desugar_rep_body(body_ir, min, max, discard?, state) do
    {mand_rhs, mand_captures, state} = desugar_repeated(body_ir, min, discard?, state)
    {tail_helper, state} = desugar_bounded_tail(body_ir, max - min, discard?, state)
    rhs = mand_rhs ++ [{:nonterminal, tail_helper}]
    tail = if discard?, do: [], else: [{length(mand_rhs), nil, :splice}]
    {rhs, mand_captures ++ tail, state}
  end

  defp desugar_repeated(_body_ir, 0, _discard?, state), do: {[], [], state}

  defp desugar_repeated(body_ir, n, discard?, state) do
    {rhs1, captures1, state} = desugar_elements(seq_elements(body_ir), discard?, state)
    {rhs_rest, captures_rest, state} = desugar_repeated(body_ir, n - 1, discard?, state)
    {rhs1 ++ rhs_rest, captures1 ++ shift_all(captures_rest, length(rhs1)), state}
  end

  # `$opt_tail_k := body $opt_tail_{k-1} | ε` -- up to `extra` further
  # optional copies, right-nested so any prefix count from 0..extra works.
  defp desugar_bounded_tail(_body_ir, 0, _discard?, state) do
    {helper, state} = fresh_helper(:opt, state)
    state = add_production(state, helper, [], [])
    {helper, state}
  end

  defp desugar_bounded_tail(body_ir, extra, discard?, state) do
    {helper, state} = fresh_helper(:opt, state)
    state = add_production(state, helper, [], [])

    {inner_helper, state} = desugar_bounded_tail(body_ir, extra - 1, discard?, state)
    {body_rhs, body_captures, state} = desugar_elements(seq_elements(body_ir), discard?, state)
    rhs = body_rhs ++ [{:nonterminal, inner_helper}]
    tail = if discard?, do: [], else: [{length(body_rhs), nil, :splice}]
    state = add_production(state, helper, rhs, body_captures ++ tail)

    {helper, state}
  end
end
