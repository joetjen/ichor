defmodule Grammar.LR.Stack do
  @moduledoc """
  The linear LR stack's shift/reduce mechanics -- shared by the
  interpreted `Grammar.LR` and `Grammar.Native.LR`'s per-state
  generated code, since a stack push/pop is exactly the same operation
  regardless of whether the state driving it came from a `Map.get` or a
  compiled `case`.

  A stack entry is `{state, start_pos, end_pos, value}`: `state` is
  needed after a reduce to know which `GOTO` to consult -- the state a
  pop exposes isn't knowable until then, even when *which* production
  reduced is already compile-time-known (the same production can be
  reduced from more than one calling context, exposing a different
  state each time). `start_pos`/`end_pos` are token-stream indices,
  needed for a `:text`-kind capture's span regardless of which RHS
  position it sits at (`Grammar.LRTable.Captures`). `value` is the
  shifted `%Grammar.VM.Token{}` itself, or a reduced nonterminal's own
  already-built captures map.
  """

  alias Grammar.LRTable.{Captures, Production}
  alias Grammar.VM.Token

  @type entry :: {state :: term(), non_neg_integer(), non_neg_integer(), term()}

  @doc "Pushes a freshly-shifted token onto `stack`, landing in `state`."
  @spec push_token([entry()], term(), Token.t(), non_neg_integer(), non_neg_integer()) :: [
          entry()
        ]
  def push_token(stack, state, token, pos, new_pos), do: [{state, pos, new_pos, token} | stack]

  @doc """
  Pops `production`'s own RHS length off `stack`, builds its captures
  via `Grammar.LRTable.Captures.build/3`, and returns `{exposed_state,
  rest_stack, start_pos, end_pos, captures}` -- `exposed_state` is
  whatever's now on top (the caller's own job to look up `GOTO` for),
  `start_pos`/`end_pos` the span the whole reduced production covers
  (both `pos`, for a zero-width/epsilon production).
  """
  @spec reduce([entry()], Production.t(), tuple(), non_neg_integer()) ::
          {term(), [entry()], non_neg_integer(), non_neg_integer(), map()}
  def reduce(stack, %Production{} = production, stream, pos) do
    n = length(production.rhs)
    {popped_rev, rest_stack} = Enum.split(stack, n)
    popped = Enum.reverse(popped_rev)

    {start_pos, end_pos} =
      case popped do
        [] -> {pos, pos}
        _ -> {elem(List.first(popped), 1), elem(List.last(popped), 2)}
      end

    entries = Enum.map(popped, fn {_state, s, e, value} -> {value, s, e} end)
    captures = Captures.build(production, entries, stream)
    [{exposed_state, _, _, _} | _] = rest_stack

    {exposed_state, rest_stack, start_pos, end_pos, captures}
  end

  @doc "Pushes a reduced nonterminal's captures onto `rest_stack` (as returned by `reduce/4`), landing in `target_state`."
  @spec push_reduced([entry()], term(), non_neg_integer(), non_neg_integer(), map()) :: [entry()]
  def push_reduced(rest_stack, target_state, start_pos, end_pos, captures),
    do: [{target_state, start_pos, end_pos, captures} | rest_stack]
end
