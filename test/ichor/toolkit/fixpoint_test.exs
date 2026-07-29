defmodule Ichor.Toolkit.FixpointTest do
  use ExUnit.Case, async: true

  alias Ichor.Toolkit.Fixpoint

  test "iterates until step_fn stops changing the value, returning that value" do
    # Grows a MapSet by one element per step until it saturates at 5 --
    # the same "monotone growth over a fixed universe" shape
    # Grammar.Analysis's nullable/always-empty computation uses.
    universe = 1..5

    result =
      Fixpoint.least(MapSet.new(), fn set ->
        Enum.reduce(universe, set, fn n, acc ->
          if n == 1 or MapSet.member?(acc, n - 1), do: MapSet.put(acc, n), else: acc
        end)
      end)

    assert result == MapSet.new(1..5)
  end

  test "a step_fn that never changes the initial value converges immediately" do
    assert Fixpoint.least(:done, fn :done -> :done end) == :done
  end

  test "works over a plain Map, not just a MapSet -- equality is just ==/2" do
    result =
      Fixpoint.least(%{a: 0}, fn map ->
        map
        |> Map.put(:a, min(Map.get(map, :a, 0) + 1, 3))
        |> Map.put_new(:b, 0)
      end)

    assert result == %{a: 3, b: 0}
  end
end
