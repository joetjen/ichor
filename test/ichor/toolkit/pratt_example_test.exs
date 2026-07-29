defmodule Ichor.Toolkit.PrattExampleTest do
  @moduledoc """
  Proves `Ichor.Toolkit.Pratt`'s prefix/infix/postfix handling (and the
  infix-vs-postfix ambiguity resolution via `can_start_operand?`) works
  outside Ichor's own grammar/token-stream domain entirely, via
  `Calculator` (`test/support/calculator.ex`).
  """

  use ExUnit.Case, async: true

  describe "infix, with ordinary precedence" do
    test "* binds tighter than +" do
      assert Calculator.eval("2 + 3 * 4") == {:ok, 14}
    end

    test "left-associative chain of the same precedence" do
      assert Calculator.eval("10 - 3 - 2") == {:ok, 5}
    end

    test "a single number with no operator" do
      assert Calculator.eval("42") == {:ok, 42}
    end
  end

  describe "prefix" do
    test "unary minus negates its operand" do
      assert Calculator.eval("-5") == {:ok, -5}
    end

    test "unary minus binds tighter than infix +, not the whole rest of the expression" do
      assert Calculator.eval("-5 + 3") == {:ok, -2}
    end
  end

  describe "postfix" do
    test "factorial" do
      assert Calculator.eval("3!") == {:ok, 6}
    end

    test "postfix ! binds tighter than infix +" do
      assert Calculator.eval("1 + 2!") == {:ok, 3}
    end
  end

  describe "% registered as both infix and postfix -- the genuine ambiguity, resolved via can_start_operand?" do
    test "a number follows -- % is infix modulo" do
      assert Calculator.eval("10 % 3") == {:ok, 1}
    end

    test "nothing follows -- % is postfix percent" do
      assert Calculator.eval("50%") == {:ok, 0.5}
    end

    test "% used postfix mid-expression, followed by another operator" do
      assert Calculator.eval("50% + 1") == {:ok, 1.5}
    end
  end

  describe "failure" do
    test "an incomplete expression fails rather than silently returning a partial result" do
      assert Calculator.eval("1 +") == :fail
    end

    test "trailing garbage after a complete expression fails" do
      assert Calculator.eval("1 2") == :fail
    end
  end
end
