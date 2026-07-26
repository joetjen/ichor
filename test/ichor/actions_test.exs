defmodule Ichor.ActionsTest.CountingActions do
  @moduledoc "Each item_rule embeds the context it saw, so evaluation order is directly observable."
  @behaviour Ichor.Actions

  @impl true
  def handle_rule(:item_rule, %{ITEM: cap}, ctx) do
    {:ok, text, ctx} = cap.eval.(ctx)
    {:ok, {text, ctx}, ctx + 1}
  end

  def handle_rule(:list, captures, ctx), do: Ichor.Actions.eval_all(captures, ctx)
end

defmodule Ichor.ActionsTest.RejectingActions do
  @behaviour Ichor.Actions

  @impl true
  def handle_token(:DIGITS, text, _ctx) do
    {:error, Ichor.Error.new(message: "digits are not allowed: #{text}", stage: :action)}
  end
end

defmodule Ichor.ActionsTest.FinalizingActions do
  @behaviour Ichor.Actions

  @impl true
  def finalize(_ctx),
    do: {:error, [Ichor.Error.new(message: "finalize always rejects", stage: :action)]}
end

defmodule Ichor.ActionsTest do
  use ExUnit.Case, async: true

  alias Ichor.ActionsTest.{CountingActions, FinalizingActions, RejectingActions}
  alias Support.NoActions

  defp compile!(source) do
    {:ok, grammar} = Aether.Parser.parse(source)
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  @calculator ~S"""
  @grammar "calculator"
  @root expr

  NUMBER := /\d+(\.\d+)?/
  SPACE  := [ \t\n]+

  expr   := term (op:("+" | "-") term)*
  term   := factor (op:("*" | "/") factor)*
  factor := NUMBER | "(" expr ")"
  """

  describe "Calculator.Actions, wired into Grammar.VM" do
    setup do
      {:ok, grammar: compile!(@calculator)}
    end

    test "precedence: 2 + 3 * 4 evaluates to 14, not 20", %{grammar: g} do
      assert {:ok, 14} = Grammar.VM.run(g, "2 + 3 * 4", Calculator.Actions)
    end

    test "a single number passes straight through", %{grammar: g} do
      assert {:ok, 2} = Grammar.VM.run(g, "2", Calculator.Actions)
    end

    test "parenthesized groups", %{grammar: g} do
      assert {:ok, 20} = Grammar.VM.run(g, "(2 + 3) * 4", Calculator.Actions)
    end

    test "left-to-right chained addition", %{grammar: g} do
      assert {:ok, 15} = Grammar.VM.run(g, "1 + 2 + 3 + 4 + 5", Calculator.Actions)
    end

    test "decimals produce floats", %{grammar: g} do
      assert {:ok, 7.0} = Grammar.VM.run(g, "3.5 * 2", Calculator.Actions)
    end

    test "division and subtraction", %{grammar: g} do
      assert {:ok, 4.0} = Grammar.VM.run(g, "10 / 2 - 1", Calculator.Actions)
    end

    test "a grammar/action mismatch (bad input) yields a Ichor.Error, not a crash", %{grammar: g} do
      assert {:error, %Ichor.Error{}} = Grammar.VM.run(g, "2 + ", Calculator.Actions)
      assert {:error, %Ichor.Error{}} = Grammar.VM.run(g, "not a number", Calculator.Actions)
    end
  end

  describe "default fallback, no Actions module needed" do
    test "exactly one capture passes straight through, unwrapped" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root wrapper
        @noskip
        INNER := [a-z]+
        wrapper := INNER
        """)

      assert {:ok, "hello"} = Grammar.VM.run(grammar, "hello", NoActions)
    end

    test "multiple captures build a %Ichor.Node{}" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root pair
        @noskip
        KEY   := [a-z]+
        COLON := ":"
        VALUE := [0-9]+
        pair := key:KEY COLON value:VALUE
        """)

      assert {:ok, %Ichor.Node{rule: :pair, captures: %{key: "a", value: "1"}}} =
               Grammar.VM.run(grammar, "a:1", NoActions)
    end

    test "a repeated capture that matched zero times is an empty list, not a missing key" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root list
        @noskip
        ITEM  := [a-z]+
        COMMA := ","
        list := first:ITEM (COMMA rest:ITEM)*
        """)

      assert {:ok, %Ichor.Node{captures: %{first: "a", rest: []}}} =
               Grammar.VM.run(grammar, "a", NoActions)

      assert {:ok, %Ichor.Node{captures: %{first: "a", rest: ["b", "c"]}}} =
               Grammar.VM.run(grammar, "a,b,c", NoActions)
    end
  end

  describe "eval_all/2" do
    test "resolves a repeated (list-valued) capture in order, threading context through each" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root list
        @noskip
        ITEM := [a-z]
        item_rule := ITEM
        list := item_rule+
        """)

      assert {:ok, %{item_rule: [{"a", 0}, {"b", 1}, {"c", 2}]}} =
               Grammar.VM.run(grammar, "abc", CountingActions, 0)
    end
  end

  describe "error propagation" do
    test "a custom handle_token returning {:error, _} propagates cleanly" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root r
        @noskip
        DIGITS := [0-9]+
        r := DIGITS
        """)

      assert {:error, %Ichor.Error{message: message}} =
               Grammar.VM.run(grammar, "123", RejectingActions)

      assert message =~ "not allowed"
    end
  end

  describe "finalize/1" do
    test "runs after the root rule evaluates, and can still reject the whole parse" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root r
        @noskip
        DIGITS := [0-9]+
        r := DIGITS
        """)

      assert {:error, [%Ichor.Error{message: "finalize always rejects"}]} =
               Grammar.VM.run(grammar, "123", FinalizingActions)
    end
  end
end
