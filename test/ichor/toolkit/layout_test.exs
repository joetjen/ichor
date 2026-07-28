defmodule Ichor.Toolkit.LayoutTest do
  @moduledoc """
  Direct unit tests of `Ichor.Toolkit.Layout`'s `step/2`/`close/1` in
  isolation. Its real-world use is proven separately by the standalone
  worked example in `test/ichor/toolkit/layout_example_test.exs`
  (`OutlineParser`, `test/support/outline_parser.ex`).
  """

  use ExUnit.Case, async: true

  alias Ichor.Toolkit.Layout

  describe "step/2: same level" do
    test "an equal width emits no markers and leaves the stack unchanged" do
      assert Layout.step(4, [4, 0]) == {:ok, [], [4, 0]}
    end

    test "width 0 against the base stack emits nothing" do
      assert Layout.step(0, [0]) == {:ok, [], [0]}
    end
  end

  describe "step/2: indent" do
    test "a greater width pushes a new level and emits one :indent" do
      assert Layout.step(4, [0]) == {:ok, [:indent], [4, 0]}
    end

    test "indenting again from a non-zero level stacks further" do
      assert Layout.step(8, [4, 0]) == {:ok, [:indent], [8, 4, 0]}
    end
  end

  describe "step/2: dedent" do
    test "a lesser width popping exactly one level emits one :dedent" do
      assert Layout.step(0, [4, 0]) == {:ok, [:dedent], [0]}
    end

    test "a width popping multiple levels at once emits one :dedent per level" do
      assert Layout.step(0, [8, 4, 0]) == {:ok, [:dedent, :dedent], [0]}
    end

    test "dedenting to a middle level stops popping exactly there" do
      assert Layout.step(4, [8, 4, 0]) == {:ok, [:dedent], [4, 0]}
    end

    test "dedenting to a width that was never pushed is an error" do
      assert Layout.step(3, [8, 4, 0]) == {:error, {:inconsistent_dedent, 3, [8, 4, 0]}}
    end

    test "an inconsistent dedent doesn't mutate the stack -- it's reported as-is" do
      {:error, {:inconsistent_dedent, 3, original_stack}} = Layout.step(3, [8, 4, 0])
      assert original_stack == [8, 4, 0]
    end
  end

  describe "close/1" do
    test "closing the base-only stack needs no dedents" do
      assert Layout.close([0]) == []
    end

    test "closing a stack with open levels emits one :dedent per level above the base" do
      assert Layout.close([8, 4, 0]) == [:dedent, :dedent]
    end
  end

  describe "a realistic sequence of steps threaded through a whole file" do
    test "indent, same, dedent, indent again, then close at end of input" do
      {markers1, stack1} = ok!(Layout.step(0, [0]))
      {markers2, stack2} = ok!(Layout.step(2, stack1))
      {markers3, stack3} = ok!(Layout.step(2, stack2))
      {markers4, stack4} = ok!(Layout.step(0, stack3))
      {markers5, stack5} = ok!(Layout.step(2, stack4))

      assert markers1 == []
      assert markers2 == [:indent]
      assert markers3 == []
      assert markers4 == [:dedent]
      assert markers5 == [:indent]
      assert stack5 == [2, 0]
      assert Layout.close(stack5) == [:dedent]
    end
  end

  defp ok!({:ok, markers, stack}), do: {markers, stack}
end
