defmodule Grammar.VM.Compiler do
  @moduledoc """
  The combinator half of Grammar.VM's bytecode compilation, shared
  between the character-level compiler (token bodies, run by the lexer)
  and the token-stream-level compiler (rule bodies, run by the parser).
  `Seq`/`Choice`/`Star`/`Plus`/`Opt`/`Rep`/`AndPred`/`NotPred` compile
  identically either way -- only the leaf nodes differ
  (`Literal`/`CharClass`/`Any`/`RuleRef` for tokens; `RuleRef`/`Indent`/
  `Capture` for rules -- tokens can never contain a `Capture`), so each
  caller supplies its own `leaf_fun` for those.

  Every `compile/3` clause returns `{ops, next_counter}`, where `ops` is a
  flat list of instructions possibly containing `{:label, n}` markers
  (resolved later by `Grammar.VM.Linker`) and `counter` is the next
  unused label number -- threaded through so nested compilation never
  reuses a label.

  The instruction set is the standard PEG/LPeg one (Ierusalimschy's
  "A Text Pattern-Matching Tool based on Parsing Expression Grammars"):
  `choice`/`commit` for ordered choice and `*`, `back_commit`/`fail_twice`
  for the two lookahead predicates. `Grammar.Analysis` already guarantees
  no `Star`/`Plus` here wraps an unconditionally-empty match at the point
  a grammar author wrote it directly, but `test_progress` below is still
  a hard runtime guarantee rather than relying on that alone -- see the
  comment on the `Star` clause.
  """

  alias Grammar.IR

  @type ops :: [term()]
  @type leaf_fun :: (IR.expr(), non_neg_integer() -> {ops(), non_neg_integer()})

  @spec compile(IR.expr(), non_neg_integer(), leaf_fun()) :: {ops(), non_neg_integer()}
  def compile(%IR.Seq{exprs: exprs}, counter, leaf_fun) do
    Enum.reduce(exprs, {[], counter}, fn e, {acc, counter} ->
      {ops, counter} = compile(e, counter, leaf_fun)
      {acc ++ ops, counter}
    end)
  end

  def compile(%IR.Choice{exprs: [only]}, counter, leaf_fun), do: compile(only, counter, leaf_fun)

  def compile(%IR.Choice{exprs: exprs}, counter, leaf_fun) do
    {lend, counter} = fresh(counter)
    compile_alts(exprs, lend, counter, leaf_fun)
  end

  # `test_progress` (not plain `commit`) at the loop-back point: guards
  # against a body that matches without consuming anything.
  # `Grammar.Analysis`'s empty-repetition check catches the simple, direct
  # cases of this at compile time, but can't see through
  # `Aether.Parser`'s own skip-splicing rewriting of `X*`/`X+` in every
  # case -- and looping a zero-width match forever is a real, silent
  # hang, not just a lint someone could choose to ignore, so this stays a
  # hard runtime guarantee independent of what the static check manages
  # to catch.
  def compile(%IR.Star{expr: e}, counter, leaf_fun) do
    {l1, counter} = fresh(counter)
    {l2, counter} = fresh(counter)
    {ops, counter} = compile(e, counter, leaf_fun)
    {[{:label, l1}, {:choice, l2}] ++ ops ++ [{:test_progress, l1}, {:label, l2}], counter}
  end

  def compile(%IR.Plus{expr: e}, counter, leaf_fun) do
    {first, counter} = compile(e, counter, leaf_fun)
    {rest, counter} = compile(%IR.Star{expr: e}, counter, leaf_fun)
    {first ++ rest, counter}
  end

  def compile(%IR.Opt{expr: e}, counter, leaf_fun) do
    {l1, counter} = fresh(counter)
    {ops, counter} = compile(e, counter, leaf_fun)
    {[{:choice, l1}] ++ ops ++ [{:commit, l1}, {:label, l1}], counter}
  end

  def compile(%IR.Rep{expr: e, min: min, max: :infinity}, counter, leaf_fun) do
    {mandatory, counter} = compile_n(e, min, counter, leaf_fun)
    {star, counter} = compile(%IR.Star{expr: e}, counter, leaf_fun)
    {mandatory ++ star, counter}
  end

  def compile(%IR.Rep{expr: e, min: min, max: max}, counter, leaf_fun) do
    {mandatory, counter} = compile_n(e, min, counter, leaf_fun)
    {optional, counter} = compile_n(%IR.Opt{expr: e}, max - min, counter, leaf_fun)
    {mandatory ++ optional, counter}
  end

  # &e: on success, roll position back (it's a lookahead, not a match) and
  # continue *past* the failure-landing instruction below; on failure,
  # the automatic backtrack already lands exactly on that instruction,
  # propagating the failure outward. Two distinct labels, deliberately --
  # collapsing them into one would make the success path fall straight
  # into the `fail` meant only for the failure path.
  def compile(%IR.AndPred{expr: e}, counter, leaf_fun) do
    {l1, counter} = fresh(counter)
    {l2, counter} = fresh(counter)
    {ops, counter} = compile(e, counter, leaf_fun)
    {[{:choice, l1}] ++ ops ++ [{:back_commit, l2}, {:label, l1}, {:fail}, {:label, l2}], counter}
  end

  # !e: on success, discard our own choice point and fail outward
  # (fail_twice); on failure, the automatic backtrack already restored
  # position, so just fall through as a (zero-width) success.
  def compile(%IR.NotPred{expr: e}, counter, leaf_fun) do
    {l1, counter} = fresh(counter)
    {ops, counter} = compile(e, counter, leaf_fun)
    {[{:choice, l1}] ++ ops ++ [{:fail_twice}, {:label, l1}], counter}
  end

  def compile(other, counter, leaf_fun), do: leaf_fun.(other, counter)

  @spec fresh(non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def fresh(counter), do: {counter, counter + 1}

  defp compile_alts([last], lend, counter, leaf_fun) do
    {ops, counter} = compile(last, counter, leaf_fun)
    {ops ++ [{:label, lend}], counter}
  end

  defp compile_alts([alt | rest], lend, counter, leaf_fun) do
    {lnext, counter} = fresh(counter)
    {alt_ops, counter} = compile(alt, counter, leaf_fun)
    {rest_ops, counter} = compile_alts(rest, lend, counter, leaf_fun)
    {[{:choice, lnext}] ++ alt_ops ++ [{:commit, lend}, {:label, lnext}] ++ rest_ops, counter}
  end

  defp compile_n(_e, 0, counter, _leaf_fun), do: {[], counter}

  defp compile_n(e, n, counter, leaf_fun) do
    {ops, counter} = compile(e, counter, leaf_fun)
    {rest, counter} = compile_n(e, n - 1, counter, leaf_fun)
    {ops ++ rest, counter}
  end
end
