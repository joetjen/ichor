defmodule Ichor.Toolkit.Codegen do
  @moduledoc """
  Small, IR-agnostic `quote`/`unquote` mechanics -- not a code
  generator, and deliberately not a framework for building one (no
  tree-walker, no visitor dispatch, no assumed node shape, no assumed
  function-signature convention). Each function here solves exactly one
  mechanical pain point that recurs when hand-writing a compiler-to-
  quoted-Elixir backend, extracted from `Grammar.Native`'s own codegen
  (`CharCompiler`, `RuleCompiler`, `Native.LR`) after the same handful
  of tricks turned up independently duplicated across (and within) those
  modules -- the same duplication signal that justified
  `Ichor.Toolkit.Fixpoint`.
  """

  @doc """
  A fresh, collision-free atom built from `prefix` and `counter`, plus
  the next counter to use -- the "how do I name my Nth generated helper
  function" pattern (`Grammar.Native.RuleCompiler`'s own
  `fresh_name/1`, `Grammar.Native.CharCompiler`'s analog, both
  hardcoded to one specific prefix before this existed).
  """
  @spec fresh(atom() | String.t(), non_neg_integer()) :: {atom(), non_neg_integer()}
  def fresh(prefix, counter), do: {:"#{prefix}#{counter}", counter + 1}

  @doc """
  A map of `name => Macro.var(name, nil)` for every name in `names` --
  the *unhygienic* variable references (`context: nil`, not a fresh
  hygiene context per `quote` call) that let two separately-quoted
  function bodies refer to the same variable by name, needed whenever
  generated functions call each other and must agree on parameter names
  (`stream`, `pos`, `context`, ...). Generalizes the ad-hoc `srp()`-style
  helper `Grammar.Native.RuleCompiler`/`CharCompiler` each wrote their
  own copy of.
  """
  @spec vars([atom()]) :: %{atom() => Macro.t()}
  def vars(names), do: Map.new(names, &{&1, Macro.var(&1, nil)})

  @doc """
  A list of `count` unhygienic variables sharing `base_name`, numbered
  from `start` (default `0`) -- `indexed_vars(:pos, 3, 1)` gives
  `pos1`, `pos2`, `pos3`. Generalizes a pattern
  `Grammar.Native.RuleCompiler`'s own `Seq` compilation already threads
  three separate instances of by hand (`pos1, pos2, ...`, `ref1, ref2,
  ...`, `cap0, cap1, ...`), one intermediate variable per sequence
  position.
  """
  @spec indexed_vars(atom() | String.t(), non_neg_integer(), non_neg_integer()) :: [Macro.t()]
  def indexed_vars(base_name, count, start \\ 0) do
    for i <- start..(start + count - 1)//1, do: Macro.var(:"#{base_name}#{i}", nil)
  end

  @doc """
  The quoted AST for `&name/arity`, buildable at macro-expansion time
  even when `name` is a plain runtime atom -- `&unquote(name)/unquote(arity)`
  doesn't work directly through `quote`/`unquote` (the capture operator
  needs a literal function reference at the AST level, not a value to
  substitute). Duplicated verbatim in both `Grammar.Native.CharCompiler`
  and `Grammar.Native.RuleCompiler` before this existed -- one of their
  own moduledocs cross-references the other's copy.
  """
  @spec capture(atom(), non_neg_integer()) :: Macro.t()
  def capture(name, arity), do: {:&, [], [{:/, [], [{name, [], nil}, arity]}]}

  @doc """
  One `pattern -> body` clause, for splicing a dynamically-sized list
  of them into a `case`/`cond`/`fn`. A bare `->` can't be written as a
  standalone quoted expression outside one of those three constructs
  (unlike, say, `<-` for a `with` clause, which is an ordinary operator
  usable anywhere) -- extracted from `Grammar.Native.LR`'s own raw
  `{:->, [], [[pattern], body]}` construction for compiling per-state
  dispatch.
  """
  @spec clause(Macro.t(), Macro.t()) :: Macro.t()
  def clause(pattern, body), do: {:->, [], [[pattern], body]}

  @doc "Like `clause/2`, but with a guard: `pattern when guard -> body`."
  @spec clause(Macro.t(), Macro.t(), Macro.t()) :: Macro.t()
  def clause(pattern, guard, body), do: {:->, [], [[{:when, [], [pattern, guard]}], body]}
end
