defmodule Grammar.GLR.Runtime do
  @moduledoc """
  The GSS-driving shift-reduce/fork loop itself, shared by the
  interpreted `Grammar.GLR` (which wraps a `Grammar.LRTable`'s plain
  action/goto maps into closures) and `Grammar.Native.GLR` (which
  passes compiled per-state functions instead) -- extracted so both
  reuse the exact same, already-proven algorithm. The graph-structured
  stack itself (node merging, multi-path reduce enumeration --
  `Grammar.GLR.GSS`) is inherently a runtime, input-driven data
  structure that can't compile away no matter which engine calls into
  it; only *how a caller looks up actions/goto for a state* varies.
  """

  alias Grammar.GLR.GSS
  alias Grammar.LRTable
  alias Grammar.LRTable.{Automaton, Captures, Production}
  alias Ichor.Error

  @type action_fn :: (Grammar.LRTable.state_id(), atom() -> [Automaton.action()])
  @type goto_fn :: (Grammar.LRTable.state_id(), atom() -> Grammar.LRTable.state_id() | nil)

  @doc "Runs the GSS shift-reduce/fork loop over `stream`, starting from `start_state`, dispatching every lookup through `action_fn`/`goto_fn`."
  @spec run(
          action_fn(),
          goto_fn(),
          %{non_neg_integer() => Production.t()},
          Grammar.LRTable.state_id(),
          atom(),
          tuple()
        ) :: {:ok, non_neg_integer(), map()} | {:error, Error.t()}
  def run(action_fn, goto_fn, productions, start_state, end_symbol, stream) do
    start_node = {start_state, 0}

    step(
      action_fn,
      goto_fn,
      productions,
      end_symbol,
      stream,
      0,
      GSS.new(),
      MapSet.new([start_node])
    )
  end

  # Tomita's own phase discipline: every reduce reachable at this
  # position runs (to a fixpoint -- a reduce can create a new active
  # node whose own reduces haven't run yet, or add a new edge into an
  # already-active one, unlocking paths a *previous* round's `paths/3`
  # call couldn't see yet) before any shift is attempted.
  defp step(action_fn, goto_fn, productions, end_symbol, stream, pos, gss, active) do
    lookahead = current_terminal(stream, pos, end_symbol)

    {gss, active} =
      reduce_to_fixpoint(action_fn, goto_fn, productions, stream, pos, gss, active, lookahead)

    accepting_nodes = Enum.filter(active, &accepting?(action_fn, &1, lookahead))

    case accepting_nodes do
      [] ->
        {gss, next_active} = shift_all(action_fn, stream, pos, gss, active, lookahead)

        if MapSet.size(next_active) == 0 do
          {:error, LRTable.unexpected_error(stream, pos)}
        else
          step(action_fn, goto_fn, productions, end_symbol, stream, pos + 1, gss, next_active)
        end

      nodes ->
        finish(gss, nodes, pos, stream)
    end
  end

  defp accepting?(action_fn, {state, _pos}, lookahead),
    do: :accept in action_fn.(state, lookahead)

  defp current_terminal(stream, pos, end_symbol),
    do: LRTable.current_terminal(stream, pos, end_symbol)

  defp reduce_to_fixpoint(action_fn, goto_fn, productions, stream, pos, gss, active, lookahead) do
    {gss2, new_nodes} =
      apply_all_reduces(action_fn, goto_fn, productions, stream, pos, gss, active, lookahead)

    active2 = MapSet.union(active, new_nodes)

    if gss2.edges == gss.edges do
      {gss2, active2}
    else
      reduce_to_fixpoint(action_fn, goto_fn, productions, stream, pos, gss2, active2, lookahead)
    end
  end

  defp apply_all_reduces(action_fn, goto_fn, productions, stream, pos, gss, active, lookahead) do
    Enum.reduce(active, {gss, MapSet.new()}, fn {state, _pos} = node, {gss, new_nodes} ->
      actions = action_fn.(state, lookahead)
      conflict? = length(actions) > 1

      actions
      |> Enum.with_index()
      |> Enum.reduce({gss, new_nodes}, fn
        {{:reduce, prod_id}, idx}, {gss, new_nodes} ->
          marker = if conflict?, do: idx, else: nil
          apply_reduce(goto_fn, productions, gss, new_nodes, stream, pos, node, prod_id, marker)

        {_other, _idx}, acc ->
          acc
      end)
    end)
  end

  defp apply_reduce(
         goto_fn,
         productions,
         gss,
         new_nodes,
         stream,
         pos,
         node,
         prod_id,
         choice_marker
       ) do
    production = Map.fetch!(productions, prod_id)
    n = length(production.rhs)

    Enum.reduce(GSS.paths(gss, node, n), {gss, new_nodes}, fn {origin, entries, path_prov},
                                                              {gss, new_nodes} ->
      {origin_state, _origin_pos} = origin
      target_state = goto_fn.(origin_state, production.lhs)
      target_node = {target_state, pos}

      captures = Captures.build(production, entries, stream)
      provenance = path_prov ++ List.wrap(choice_marker)

      gss2 = GSS.add_edge(gss, origin, target_node, captures, provenance)
      {gss2, MapSet.put(new_nodes, target_node)}
    end)
  end

  defp shift_all(_action_fn, stream, pos, gss, _active, _lookahead)
       when pos >= tuple_size(stream) do
    {gss, MapSet.new()}
  end

  defp shift_all(action_fn, stream, pos, gss, active, lookahead) do
    token = elem(stream, pos)

    Enum.reduce(active, {gss, MapSet.new()}, fn {state, _pos} = node, {gss, next_active} ->
      actions = action_fn.(state, lookahead)
      conflict? = length(actions) > 1

      actions
      |> Enum.with_index()
      |> Enum.reduce({gss, next_active}, fn
        {{:shift, target}, idx}, {gss, next_active} ->
          next_node = {target, pos + 1}
          provenance = if conflict?, do: [idx], else: []
          gss2 = GSS.add_edge(gss, node, next_node, token, provenance)
          {gss2, MapSet.put(next_active, next_node)}

        {_other, _idx}, acc ->
          acc
      end)
    end)
  end

  # Every accepting node's own incoming edges are each a complete,
  # distinct derivation of the *entire* input (that edge's `value` is
  # `root`'s own already-built captures map, spliced transparently up
  # through `$start`'s reduce the same way `Grammar.LR` reads it
  # straight off the stack top) -- more than one means genuine
  # ambiguity survived to the very end, broken by whichever recorded
  # the earliest-declared choice at its first conflict point.
  defp finish(gss, accepting_nodes, pos, stream) do
    candidates =
      for node <- accepting_nodes, {_origin, value, provenance} <- GSS.incoming(gss, node) do
        {provenance, value}
      end

    case candidates do
      [] ->
        {:error, LRTable.unexpected_error(stream, pos)}

      _ ->
        {_provenance, captures} = Enum.min_by(candidates, fn {prov, _value} -> prov end)
        {:ok, pos, captures}
    end
  end
end
