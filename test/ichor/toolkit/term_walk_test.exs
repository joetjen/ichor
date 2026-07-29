defmodule Ichor.Toolkit.TermWalkTest do
  @moduledoc """
  Direct unit tests of `Ichor.Toolkit.TermWalk`'s `fold/4`/`rewrite/3` in
  isolation, over a minimal `Ichor.Backtrack.Term` implementation
  defined right here (`{:leaf, v}` atomic values, `{:var, id}`
  variables, `{:node, [children]}` compounds). Its real-world use is
  proven separately: the refactor of `Ichor.Toolkit.TypeScheme`
  (`resolve_deep/3`, the private `substitute/3`, `free_vars/3` -- this
  module's own moduledoc cites all three), and the standalone,
  unrelated-domain worked example in
  `test/ichor/toolkit/term_walk_example_test.exs` (`Template`,
  `test/support/template.ex`).
  """

  use ExUnit.Case, async: true

  alias Ichor.Toolkit.TermWalk

  defmodule T do
    @behaviour Ichor.Backtrack.Term

    @impl true
    def variable?({:var, _id}), do: true
    def variable?(_), do: false

    @impl true
    def var_id({:var, id}), do: id

    @impl true
    def compound?({:node, _children}), do: true
    def compound?(_), do: false

    @impl true
    def deconstruct({:node, children}), do: {:node, children}

    @impl true
    def reconstruct(:node, children), do: {:node, children}
  end

  describe "fold/4" do
    test "a leaf just gets combined once" do
      assert TermWalk.fold(T, {:leaf, 1}, [], &[&1 | &2]) == [{:leaf, 1}]
    end

    test "visits a node before its children" do
      term = {:node, [{:leaf, 1}, {:leaf, 2}]}
      assert TermWalk.fold(T, term, [], &[&1 | &2]) == [{:leaf, 2}, {:leaf, 1}, term]
    end

    test "recurses into nested compounds" do
      term = {:node, [{:node, [{:leaf, 1}]}, {:leaf, 2}]}

      count =
        TermWalk.fold(T, term, 0, fn
          {:leaf, _}, acc -> acc + 1
          _other, acc -> acc
        end)

      assert count == 2
    end

    test "collecting variable ids into a set, ignoring everything else" do
      term = {:node, [{:var, :x}, {:leaf, 1}, {:node, [{:var, :y}, {:var, :x}]}]}

      vars =
        TermWalk.fold(T, term, MapSet.new(), fn
          {:var, id}, acc -> MapSet.put(acc, id)
          _other, acc -> acc
        end)

      assert vars == MapSet.new([:x, :y])
    end

    test "a compound with no children still visits itself" do
      assert TermWalk.fold(T, {:node, []}, [], &[&1 | &2]) == [{:node, []}]
    end
  end

  describe "rewrite/3" do
    test "a leaf is transformed once, and that's the whole result" do
      assert TermWalk.rewrite(T, {:leaf, 1}, fn {:leaf, n} -> {:leaf, n * 10} end) ==
               {:leaf, 10}
    end

    test "an unchanged transform leaves the whole structure unchanged" do
      term = {:node, [{:leaf, 1}, {:node, [{:leaf, 2}]}]}
      assert TermWalk.rewrite(T, term, & &1) == term
    end

    test "recurses into every leaf of a nested structure" do
      term = {:node, [{:leaf, 1}, {:node, [{:leaf, 2}, {:leaf, 3}]}]}

      transform = fn
        {:leaf, n} -> {:leaf, n * 10}
        other -> other
      end

      assert TermWalk.rewrite(T, term, transform) ==
               {:node, [{:leaf, 10}, {:node, [{:leaf, 20}, {:leaf, 30}]}]}
    end

    test "substituting a variable for a leaf, leaving other variables untouched" do
      term = {:node, [{:var, :x}, {:var, :y}]}

      transform = fn
        {:var, :x} -> {:leaf, 99}
        other -> other
      end

      assert TermWalk.rewrite(T, term, transform) == {:node, [{:leaf, 99}, {:var, :y}]}
    end

    test "the transform runs once per node, before recursion -- it never sees a node this call already rebuilt" do
      term = {:node, [{:leaf, 1}, {:leaf, 2}]}

      transform = fn
        {:leaf, n} -> {:leaf, n * 10}
        # If rewrite/3 re-applied transform to a freshly-rebuilt compound,
        # this clause would fire once the children become {:leaf, 10}/
        # {:leaf, 20} -- it never does, so the node stays a :node, not :collapsed.
        {:node, [{:leaf, 10}, {:leaf, 20}]} -> :collapsed
        other -> other
      end

      assert TermWalk.rewrite(T, term, transform) == {:node, [{:leaf, 10}, {:leaf, 20}]}
    end
  end
end
