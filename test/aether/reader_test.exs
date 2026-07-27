defmodule Aether.ReaderTest do
  use ExUnit.Case, async: true

  alias Aether.Reader

  defp ok!(source) do
    case Reader.read(source) do
      {:ok, grammar} ->
        grammar

      {:error, error} ->
        flunk("expected #{inspect(source)} to read, got:\n#{Ichor.Error.format(error)}")
    end
  end

  defp fails(source) do
    case Reader.read(source) do
      {:error, error} -> error
      {:ok, _} -> flunk("expected #{inspect(source)} to fail to read")
    end
  end

  describe "no desugaring happens at this layer" do
    test "an inline rule-body string literal is kept raw, not promoted to an ANON token" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        r := "hello"
        """)

      assert {:rule, :r, {:literal, "hello", :default, _pos}, _def_pos} =
               List.keyfind(grammar.defs, :r, 1)
    end

    test "a character class is kept as raw items, not desugared into Grammar.IR" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        FOO := [a-z[:digit:]]
        r := FOO
        """)

      assert {:token, :FOO, {:char_class, false, items, _pos}, _def_pos} =
               List.keyfind(grammar.defs, :FOO, 1)

      assert {:range, ?a, ?z} in items
      assert {:posix, :digit} in items
    end

    test "a /pattern/ regex literal is kept as raw pattern text" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        NUMBER := /\d+/
        r := NUMBER
        """)

      assert {:token, :NUMBER, {:regex, "\\d+", _pos}, _def_pos} =
               List.keyfind(grammar.defs, :NUMBER, 1)
    end

    test "a predefined-token override placed after use is not flagged -- that's Eval's job" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        r := DIGIT
        DIGIT := [0-9]
        """)

      assert {:token, :DIGIT, _cst, _pos} = List.keyfind(grammar.defs, :DIGIT, 1)
    end

    test "@skip's custom token name is recorded but not resolved against anything yet" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        @skip TRIVIA
        TRIVIA := " "
        r := "a" "b"
        """)

      assert grammar.skip_mode == {:custom, :TRIVIA}
    end
  end

  describe "reader-level errors still fire with today's messages/positions" do
    test "bad syntax reports a parser-stage error" do
      error = fails("@grammar \"t\"\n@root r\nr := \n")
      assert error.stage == :parser
    end

    test "@skip given twice is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        @skip A
        @skip B
        A := "a"
        B := "b"
        r := A
        """)

      assert error.message =~ "@skip/@noskip may only be given once"
    end

    test "a duplicate ordinary token name is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        FOO := "a"
        FOO := "b"
        r := FOO
        """)

      assert error.message =~ "token FOO is already declared"
    end

    test "a duplicate rule name is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        r := "a"
        r := "b"
        """)

      assert error.message =~ "rule r is already declared"
    end

    test "a token body referencing a rule is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        FOO := bar
        r := "x"
        """)

      assert error.message =~ "may only reference other tokens"
    end

    test "a redeclared predefined token name is NOT rejected here -- Eval owns that check" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        DIGIT := [0-9]
        DIGIT := [0-9]
        r := DIGIT
        """)

      assert grammar.defs |> Enum.count(&match?({:token, :DIGIT, _, _}, &1)) == 2
    end
  end
end
