defmodule Ichor.Toolkit.ResultTest do
  @moduledoc """
  Direct unit tests of `Ichor.Toolkit.Result`'s two functions in
  isolation. Its real-world use is proven separately: the refactors of
  `Ichor.Actions`, the five grammar-family `*.Actions` modules'
  `build_ruleset/1`, `Ichor.Backtrack.Bindings.unify_compound/5`, and
  `Aether.Eval` (this module's own moduledoc cites each), and the
  standalone, compiler-unrelated worked example in
  `test/ichor/toolkit/result_example_test.exs` (`RecordImporter`,
  `test/support/record_importer.ex`).
  """

  use ExUnit.Case, async: true

  alias Ichor.Toolkit.Result

  describe "reduce_ok/3" do
    test "threads the accumulator through every element on success" do
      assert Result.reduce_ok([1, 2, 3], 0, fn x, acc -> {:ok, acc + x} end) == {:ok, 6}
    end

    test "an empty collection returns the initial accumulator unchanged" do
      assert Result.reduce_ok([], :seed, fn _x, acc -> {:ok, acc} end) == {:ok, :seed}
    end

    test "stops at the first non-ok result and returns it verbatim" do
      step = fn
        x, _acc when x < 0 -> {:error, "negative: #{x}"}
        x, acc -> {:ok, acc + x}
      end

      assert Result.reduce_ok([1, 2, -3, 4], 0, step) == {:error, "negative: -3"}
    end

    test "never calls step again after a failure -- later elements are unreachable" do
      step = fn
        :boom, _acc -> {:error, :boom}
        x, acc -> {:ok, [x | acc]}
      end

      assert Result.reduce_ok([1, :boom, :unreachable], [], step) == {:error, :boom}
    end

    test "passes through a bare atom failure sentinel, not just {:error, _} tuples" do
      step = fn
        2, _acc -> :fail
        x, acc -> {:ok, acc + x}
      end

      assert Result.reduce_ok([1, 2, 3], 0, step) == :fail
    end
  end

  describe "map_ok/3" do
    test "collects each step's value in order while threading state" do
      step = fn x, running_sum -> {:ok, x * x, running_sum + x} end

      assert Result.map_ok([1, 2, 3], 0, step) == {:ok, [1, 4, 9], 6}
    end

    test "an empty list returns an empty result list and the untouched initial state" do
      assert Result.map_ok([], :seed, fn x, state -> {:ok, x, state} end) == {:ok, [], :seed}
    end

    test "stops at the first failure and returns it verbatim, collecting nothing" do
      step = fn
        x, _state when x < 0 -> {:error, "negative: #{x}"}
        x, state -> {:ok, x, state}
      end

      assert Result.map_ok([1, -2, 3], nil, step) == {:error, "negative: -2"}
    end

    test "state threads sequentially -- each step sees the previous step's new state" do
      step = fn x, seen -> {:ok, x, MapSet.put(seen, x)} end

      assert Result.map_ok([1, 2, 2, 3], MapSet.new(), step) ==
               {:ok, [1, 2, 2, 3], MapSet.new([1, 2, 3])}
    end
  end
end
