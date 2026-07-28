defmodule Grammar.GLR.GSS do
  @moduledoc """
  The graph-structured stack itself: nodes keyed by `{state,
  stream_position}` (deduplicated -- two derivations that reach the same
  state at the same position share one node, the actual efficiency win
  over independent parallel stacks), edges labeled with whatever that
  edge's own transition produced (a shifted `%Grammar.VM.Token{}`, or a
  reduced nonterminal's own already-built captures map) plus the
  provenance accumulated along it so far.

  A node can have more than one incoming edge exactly when two
  previously-distinct derivations converge (a shift/reduce or
  reduce/reduce conflict both survived, or two different reduce paths
  happen to land on the same state and position) -- that's genuine local
  ambiguity, not a bug, and `paths/3`'s whole job is enumerating every
  distinct way to walk backward through however many edges a reduce
  needs to pop, independently for each of a node's incoming edges.

  Positions live on the node identity itself (`{state, position}`), not
  on the edge -- which is what makes a `:text`-kind capture's span
  (`Grammar.LRTable.Captures`) derivable per RHS position directly from
  the two nodes an edge connects, with no separate bookkeeping needed.
  """

  @type node_id :: {Grammar.LRTable.state_id(), non_neg_integer()}
  @type provenance :: [non_neg_integer()]
  @type edge :: {node_id(), term(), provenance()}

  @type t :: %__MODULE__{edges: %{node_id() => [edge()]}}

  defstruct edges: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Adds an edge `from -> to` labeled `value`/`provenance`, unless an identical one already exists."
  @spec add_edge(t(), node_id(), node_id(), term(), provenance()) :: t()
  def add_edge(%__MODULE__{} = gss, from, to, value, provenance) do
    edge = {from, value, provenance}
    existing = Map.get(gss.edges, to, [])

    if edge in existing do
      gss
    else
      %{gss | edges: Map.put(gss.edges, to, [edge | existing])}
    end
  end

  @spec incoming(t(), node_id()) :: [edge()]
  def incoming(%__MODULE__{} = gss, node), do: Map.get(gss.edges, node, [])

  @doc """
  Every distinct length-`k` backward path from `node`: `{origin_node,
  entries, combined_provenance}`, `entries` in left-to-right (RHS)
  order as `Grammar.LRTable.Captures.entry()` triples (`{value,
  start_pos, end_pos}`, the span read straight off the two nodes each
  edge connects). More than one result means the popped span was
  reached via more than one derivation -- local ambiguity, resolved
  later by comparing accumulated provenance, not decided here.
  """
  @spec paths(t(), node_id(), non_neg_integer()) ::
          [{node_id(), [Grammar.LRTable.Captures.entry()], provenance()}]
  def paths(_gss, node, 0), do: [{node, [], []}]

  def paths(%__MODULE__{} = gss, node, k) do
    {_state, node_pos} = node

    for {parent, value, edge_prov} <- incoming(gss, node),
        {_pstate, parent_pos} = parent,
        {origin, entries, prov} <- paths(gss, parent, k - 1) do
      {origin, entries ++ [{value, parent_pos, node_pos}], prov ++ edge_prov}
    end
  end
end
