defmodule Ichor.Toolkit.Graph do
  @moduledoc """
  Small, generic graph primitives -- extracted from `Grammar.Analysis`'s
  own private `reachable/2`/`do_reachable/3` (used to detect left
  recursion: a rule is left-recursive exactly when it's reachable from
  its own leading references). Nothing here is grammar-specific --
  `neighbors_fn` is the caller's own adjacency, a plain function rather
  than a hardcoded map, so this works over whatever graph an author's
  own AST/IR/dependency structure represents, not just Ichor's own
  rule-reference graphs.
  """

  # MapSet's own internal representation isn't fixed across Elixir/OTP
  # versions (a `:sets`-record-based union vs. a plain-map-based one),
  # which Dialyzer's success typing for a plain `MapSet.new/0` ->
  # `MapSet.put/2` accumulator (ordinary, idiomatic usage -- nothing
  # about this loop reaches around MapSet's own API) resolves to a
  # union wider than the opaque `MapSet.t()` contract this module's own
  # `@spec` declares -- a known Dialyzer/dialyxir false positive on
  # newer OTP, not a real bug (see also `Ichor.ABNF`'s own `@dialyzer`
  # note on the same underlying opaqueness quirk).
  @dialyzer :no_opaque

  @doc """
  Every node reachable from `start_nodes` (inclusive) by repeatedly
  following `neighbors_fn`. To check "is `node` reachable from
  itself" (a cycle, not trivial zero-hop self-membership) -- the
  left-recursion-detection use case this was extracted from -- start
  from `neighbors_fn.(node)` rather than `[node]` itself.
  """
  @spec reachable(Enumerable.t(node), (node -> Enumerable.t(node))) :: MapSet.t(node)
        when node: term()
  def reachable(start_nodes, neighbors_fn) do
    do_reachable(Enum.to_list(start_nodes), neighbors_fn, MapSet.new())
  end

  defp do_reachable([], _neighbors_fn, acc), do: acc

  defp do_reachable([node | rest], neighbors_fn, acc) do
    if MapSet.member?(acc, node) do
      do_reachable(rest, neighbors_fn, acc)
    else
      next = Enum.to_list(neighbors_fn.(node))
      do_reachable(next ++ rest, neighbors_fn, MapSet.put(acc, node))
    end
  end
end
