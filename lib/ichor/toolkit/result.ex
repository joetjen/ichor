defmodule Ichor.Toolkit.Result do
  @moduledoc """
  The generic "walk a collection, threading an accumulator through a
  fallible step, stopping at the first failure" primitive -- extracted
  from a pattern independently hand-rolled at least ten times across
  Ichor's own compiler internals before this existed: `build_ruleset/1`
  (duplicated near-verbatim across `Ichor.EBNF.ISO.Actions`,
  `Ichor.EBNF.W3C.Actions`, `Ichor.BNF.Actions`, `Ichor.ABNF.Actions`, and
  `Ichor.PEG.Actions`), `Ichor.Backtrack.Bindings.unify_compound/5`'s
  inner reduce over zipped compound-term arguments (whose failure
  sentinel is a bare `:fail`, not `{:error, _}`), `Aether.Eval.process_defs/2`,
  and -- byte-for-byte identical to each other -- `Ichor.Actions.eval_one/2`'s
  list-of-captures branch, `Aether.Eval.convert_list/3`, and
  `Aether.Eval.convert_seq_terms/3`.

  Elixir's stdlib has no `Enum`/`Result`-traverse equivalent to lean on
  here (unlike, say, Haskell's `Traversable` or Rust's
  `Iterator::collect::<Result<_, _>>`), which is exactly why this ended
  up hand-rolled so many times.

  Both functions pass any non-`{:ok, _}` step result straight through,
  unexamined -- deliberately, so the toolkit never has an opinion on
  what a "failure" looks like: it works equally for a bare `:fail` atom
  (`Bindings.unify_compound/5`'s convention) and for `{:error, reason}`
  (every other call site's convention).
  """

  @doc """
  Like `Enum.reduce/3`, but `step` returns `{:ok, new_acc}` to continue
  or anything else to stop immediately and return that value instead --
  the "reduce with early exit on failure" shape `build_ruleset/1`,
  `unify_compound/5`, and `process_defs/2` each wrote their own copy of.
  """
  @spec reduce_ok(Enumerable.t(elem), acc, (elem, acc -> {:ok, acc} | failure)) ::
          {:ok, acc} | failure
        when elem: term(), acc: term(), failure: term()
  def reduce_ok(enumerable, acc, step) do
    Enum.reduce_while(enumerable, {:ok, acc}, fn elem, {:ok, acc} ->
      case step.(elem, acc) do
        {:ok, new_acc} -> {:cont, {:ok, new_acc}}
        failure -> {:halt, failure}
      end
    end)
  end

  @doc """
  Maps `step` over `list` in order, collecting each `value` it produces
  while threading `state` through sequentially, stopping at the first
  failure -- exactly the shape `eval_one/2`'s list branch, `convert_list/3`,
  and `convert_seq_terms/3` each independently wrote (build the result
  via `[v | acc]`, reverse once at the end, thread state, halt on
  failure). Built on `reduce_ok/2` rather than duplicating its own
  `Enum.reduce_while`.
  """
  @spec map_ok([elem], state, (elem, state -> {:ok, value, state} | failure)) ::
          {:ok, [value], state} | failure
        when elem: term(), state: term(), value: term(), failure: term()
  def map_ok(list, state, step) do
    case reduce_ok(list, {[], state}, fn elem, {acc, state} ->
           case step.(elem, state) do
             {:ok, value, new_state} -> {:ok, {[value | acc], new_state}}
             failure -> failure
           end
         end) do
      {:ok, {acc, state}} -> {:ok, Enum.reverse(acc), state}
      failure -> failure
    end
  end
end
