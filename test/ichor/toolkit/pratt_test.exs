defmodule Ichor.Toolkit.PrattTest do
  @moduledoc """
  Direct unit tests of `Ichor.Toolkit.Pratt` in isolation, over a
  minimal token stream (a tuple mixing numbers as primaries and strings
  as potential operator names). Its real-world use is proven separately:
  the refactor of `OpExprTest.Operators.parse_infix/4` (this module's
  own moduledoc cites it), and the standalone, compiler-unrelated worked
  example in `test/ichor/toolkit/pratt_example_test.exs` (`Calculator`,
  `test/support/calculator.ex`).
  """

  use ExUnit.Case, async: true

  alias Ichor.Toolkit.Pratt

  defp callbacks(tokens, extra \\ %{}) do
    Map.merge(
      %{
        peek_op: &peek_op(tokens, &1),
        parse_primary: &parse_primary(tokens, &1),
        build: fn fixity, op, args -> {fixity, op, args} end
      },
      extra
    )
  end

  defp peek_op(tokens, pos) do
    if pos < tuple_size(tokens) and is_binary(elem(tokens, pos)) do
      {elem(tokens, pos), pos + 1}
    end
  end

  defp parse_primary(tokens, pos) do
    if pos < tuple_size(tokens) and is_number(elem(tokens, pos)) do
      {:ok, pos + 1, elem(tokens, pos)}
    else
      :fail
    end
  end

  describe "table building" do
    test "new/0 is empty" do
      assert Pratt.new() == %{}
    end

    test "prefix/3, infix/4 (default :left), and postfix/3 each register one fixity" do
      table =
        Pratt.new()
        |> Pratt.prefix("-", 100)
        |> Pratt.infix("+", 10)
        |> Pratt.postfix("!", 30)

      assert table == %{
               "-" => %{prefix: 100},
               "+" => %{infix: {10, :left}},
               "!" => %{postfix: 30}
             }
    end

    test "infix/4 accepts an explicit associativity" do
      assert Pratt.infix(Pratt.new(), "^", 40, :right) == %{"^" => %{infix: {40, :right}}}
    end

    test "the same operator can hold multiple fixities at once" do
      table = Pratt.new() |> Pratt.prefix("-", 100) |> Pratt.infix("-", 10)
      assert table == %{"-" => %{prefix: 100, infix: {10, :left}}}
    end
  end

  describe "parse/4: infix" do
    test "a bare primary with no operator" do
      assert Pratt.parse(Pratt.new(), 0, callbacks({42})) == {:ok, 1, 42}
    end

    test "left-associativity groups a chain to the left" do
      table = Pratt.infix(Pratt.new(), "-", 10)
      tokens = {10, "-", 3, "-", 2}

      assert Pratt.parse(table, 0, callbacks(tokens)) ==
               {:ok, 5, {:infix, "-", [{:infix, "-", [10, 3]}, 2]}}
    end

    test "right-associativity groups a chain to the right" do
      table = Pratt.infix(Pratt.new(), "^", 10, :right)
      tokens = {2, "^", 3, "^", 2}

      assert Pratt.parse(table, 0, callbacks(tokens)) ==
               {:ok, 5, {:infix, "^", [2, {:infix, "^", [3, 2]}]}}
    end

    test "higher precedence binds tighter" do
      table = Pratt.new() |> Pratt.infix("+", 10) |> Pratt.infix("*", 20)
      tokens = {2, "+", 3, "*", 4}

      assert Pratt.parse(table, 0, callbacks(tokens)) ==
               {:ok, 5, {:infix, "+", [2, {:infix, "*", [3, 4]}]}}
    end

    test "stops (doesn't fail) at an unregistered operator, returning what it has so far" do
      table = Pratt.infix(Pratt.new(), "+", 10)
      assert Pratt.parse(table, 0, callbacks({1, "mystery", 2})) == {:ok, 1, 1}
    end
  end

  describe "parse/4: prefix" do
    test "a bare prefix application" do
      table = Pratt.prefix(Pratt.new(), "-", 100)
      assert Pratt.parse(table, 0, callbacks({"-", 5})) == {:ok, 2, {:prefix, "-", [5]}}
    end

    test "prefix binds tighter than a lower-precedence infix that follows" do
      table = Pratt.new() |> Pratt.prefix("-", 100) |> Pratt.infix("+", 10)
      tokens = {"-", 5, "+", 3}

      assert Pratt.parse(table, 0, callbacks(tokens)) ==
               {:ok, 4, {:infix, "+", [{:prefix, "-", [5]}, 3]}}
    end
  end

  describe "parse/4: postfix" do
    test "a bare postfix application" do
      table = Pratt.postfix(Pratt.new(), "!", 30)
      assert Pratt.parse(table, 0, callbacks({5, "!"})) == {:ok, 2, {:postfix, "!", [5]}}
    end

    test "postfix binds tighter than a lower-precedence infix that follows" do
      table = Pratt.new() |> Pratt.postfix("!", 30) |> Pratt.infix("+", 10)
      tokens = {5, "!", "+", 3}

      assert Pratt.parse(table, 0, callbacks(tokens)) ==
               {:ok, 4, {:infix, "+", [{:postfix, "!", [5]}, 3]}}
    end
  end

  describe "parse/4: infix and postfix sharing an operator name" do
    test "with can_start_operand?, a following operand means infix" do
      table = Pratt.new() |> Pratt.infix("%", 20) |> Pratt.postfix("%", 30)
      tokens = {10, "%", 3}

      cbs =
        callbacks(tokens, %{
          can_start_operand?: fn pos ->
            pos < tuple_size(tokens) and is_number(elem(tokens, pos))
          end
        })

      assert Pratt.parse(table, 0, cbs) == {:ok, 3, {:infix, "%", [10, 3]}}
    end

    test "with can_start_operand?, nothing following means postfix" do
      table = Pratt.new() |> Pratt.infix("%", 20) |> Pratt.postfix("%", 30)
      tokens = {10, "%"}

      cbs =
        callbacks(tokens, %{
          can_start_operand?: fn pos ->
            pos < tuple_size(tokens) and is_number(elem(tokens, pos))
          end
        })

      assert Pratt.parse(table, 0, cbs) == {:ok, 2, {:postfix, "%", [10]}}
    end

    test "without can_start_operand?, the ambiguity raises rather than silently misparsing" do
      table = Pratt.new() |> Pratt.infix("%", 20) |> Pratt.postfix("%", 30)
      tokens = {10, "%", 3}

      assert_raise ArgumentError, ~r/"%".*both :infix and :postfix/, fn ->
        Pratt.parse(table, 0, callbacks(tokens))
      end
    end

    test "no ambiguity, and can_start_operand? never called, when only one fixity is viable at the current min_prec" do
      # infix precedence (5) is below min_prec (10), so only postfix (30) is
      # viable -- resolved directly, without ever needing to disambiguate.
      table = Pratt.new() |> Pratt.infix("%", 5) |> Pratt.postfix("%", 30)
      tokens = {10, "%"}

      assert Pratt.parse(table, 0, callbacks(tokens), 10) == {:ok, 2, {:postfix, "%", [10]}}
    end
  end

  describe "parse/4: failure propagation" do
    test "an empty stream with no primary fails" do
      assert Pratt.parse(Pratt.new(), 0, callbacks({})) == :fail
    end

    test "a prefix operator with no valid operand fails" do
      table = Pratt.prefix(Pratt.new(), "-", 100)
      assert Pratt.parse(table, 0, callbacks({"-"})) == :fail
    end

    test "an infix operator with no valid right operand fails" do
      table = Pratt.infix(Pratt.new(), "+", 10)
      assert Pratt.parse(table, 0, callbacks({1, "+"})) == :fail
    end
  end
end
