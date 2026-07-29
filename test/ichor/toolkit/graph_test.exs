defmodule Ichor.Toolkit.GraphTest do
  use ExUnit.Case, async: true

  alias Ichor.Toolkit.Graph

  @graph %{a: [:b], b: [:c], c: []}

  defp neighbors(node), do: Map.get(@graph, node, [])

  test "reachable/2 includes every start node plus everything reachable from it" do
    assert Graph.reachable([:a], &neighbors/1) == MapSet.new([:a, :b, :c])
  end

  test "a node with no outgoing edges reaches only itself" do
    assert Graph.reachable([:c], &neighbors/1) == MapSet.new([:c])
  end

  test "multiple start nodes union their own reachable sets" do
    assert Graph.reachable([:b, :c], &neighbors/1) == MapSet.new([:b, :c])
  end

  test "a genuine cycle is detected by seeding with the node's own neighbors, not the node itself" do
    cyclic = %{a: [:b], b: [:a]}
    neighbors_fn = fn n -> Map.get(cyclic, n, []) end

    # Seeding with [:a] itself would trivially include :a (start nodes are
    # always included) -- seeding with a's own neighbors is what actually
    # proves :a is reachable *from* :a, i.e. a real cycle.
    assert MapSet.member?(Graph.reachable(neighbors_fn.(:a), neighbors_fn), :a)
    refute MapSet.member?(Graph.reachable([:c], fn _ -> [] end), :a)
  end

  test "works with a MapSet-valued neighbors function too, not just lists" do
    ms_graph = %{a: MapSet.new([:b]), b: MapSet.new([])}
    neighbors_fn = fn n -> Map.get(ms_graph, n, MapSet.new()) end
    assert Graph.reachable([:a], neighbors_fn) == MapSet.new([:a, :b])
  end
end
