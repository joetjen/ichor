defmodule Grammar.NativeGLRTest do
  use ExUnit.Case, async: true

  describe "the PEG greedy-commit-failure gap, compiled: rule := A A | A, top := rule A" do
    test "Native.PegGap parses \"aa\" by forking at rule's choice point, same as interpreted Grammar.GLR" do
      assert Native.PegGap.run("aa") == {:ok, 1}
    end

    test "\"aaa\" only has one valid split (rule = AA, top's own trailing A)" do
      assert Native.PegGap.run("aaa") == {:ok, 2}
    end

    test "input with no valid split at all is still a clean parse error, not a crash" do
      assert {:error, _} = Native.PegGap.run("aaaa")
      assert {:error, _} = Native.PegGap.run("")
    end

    test "parse/1 is a bare recognizer, returning the consumed position and raw captures" do
      assert {:ok, 2, _raw_captures} = Native.PegGap.parse("aa")
    end
  end

  describe "declared-order tie-break on genuine ambiguity, compiled: s := a | b, a := X, b := X" do
    test "a declared first in s's own alternatives -- Native.AmbigTiebreak picks the a-rooted derivation" do
      assert Native.AmbigTiebreak.run("x") == {:ok, :picked_a}
    end
  end

  describe "the classic dangling-else ambiguity, compiled -- Native.DanglingElse agrees with interpreted Grammar.GLR" do
    test "an unambiguous single if/else" do
      assert Native.DanglingElse.run("if c then 1 else 2") == {:ok, {:if, :c, 1, 2}}
    end

    test "nested if/then/else -- else attaches to the nearest (inner) if" do
      assert Native.DanglingElse.run("if c then if d then 1 else 2") ==
               {:ok, {:if, :c, {:if, :d, 1, 2}, nil}}
    end

    test "a nested if with no else at all" do
      assert Native.DanglingElse.run("if c then if d then 1") ==
               {:ok, {:if, :c, {:if, :d, 1, nil}, nil}}
    end
  end
end
