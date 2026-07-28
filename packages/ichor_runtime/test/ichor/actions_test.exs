defmodule Ichor.ActionsTest do
  use ExUnit.Case, async: true

  describe "evaluate_node/3" do
    test "a raw token node dispatches to handle_token (or the default: raw text)" do
      assert {:ok, "hi", :ctx} =
               Ichor.Actions.evaluate_node({:token, :WORD, "hi"}, Support.NoActions, :ctx)
    end

    test "a raw text node evaluates to its own text, context unchanged" do
      assert {:ok, "abc", :ctx} =
               Ichor.Actions.evaluate_node({:text, "abc"}, Support.NoActions, :ctx)
    end

    test "a raw rule node dispatches to handle_rule (or the default fallback)" do
      raw = {:rule, :pair, %{key: {:token, :WORD, "a"}, value: {:token, :NUMBER, "1"}}}

      assert {:ok, %Ichor.Node{rule: :pair, captures: %{key: "a", value: "1"}}, :ctx} =
               Ichor.Actions.evaluate_node(raw, Support.NoActions, :ctx)
    end
  end
end
