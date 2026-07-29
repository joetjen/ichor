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

    test "@engine defaults to :peg when omitted" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        r := "a"
        """)

      assert grammar.engine == :peg
    end

    test "@engine lr/@engine glr are recorded" do
      lr = ok!("@grammar \"t\"\n@root r\n@engine lr\nr := \"a\"\n")
      glr = ok!("@grammar \"t\"\n@root r\n@engine glr\nr := \"a\"\n")

      assert lr.engine == :lr
      assert glr.engine == :glr
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

    test "@engine given twice is rejected" do
      error = fails("@grammar \"t\"\n@root r\n@engine lr\n@engine glr\nr := \"a\"\n")
      assert error.message =~ "@engine may only be given once"
    end

    test "an unknown @engine name is rejected" do
      error = fails("@grammar \"t\"\n@root r\n@engine bison\nr := \"a\"\n")
      assert error.message =~ "unknown @engine"
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

  describe "@native(...)/@hint(...)" do
    test "parses with no @hint, leaving both facts nil (Eval resolves the defaults)" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        primary := "x"
        r := @native("M", "f", primary)
        """)

      assert {:rule, :r, {:native, "M", "f", [:primary], hint, _pos}, _def_pos} =
               List.keyfind(grammar.defs, :r, 1)

      assert hint == %{nullable: nil, leading: nil}
    end

    test "parses an explicit @hint" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        primary := "x"
        r := @native("M", "f", primary) @hint(nullable: true, leading: (primary))
        """)

      assert {:rule, :r, {:native, "M", "f", [:primary], hint, _pos}, _def_pos} =
               List.keyfind(grammar.defs, :r, 1)

      assert hint == %{nullable: true, leading: [:primary]}
    end

    test "@native is also parseable inside a token body (a Grammar.IR.CustomLexeme, once Eval runs)" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        FOO := @native("M", "f")
        r := "x"
        """)

      assert {:token, :FOO, {:native, "M", "f", [], _hint, _pos}, _def_pos} =
               List.keyfind(grammar.defs, :FOO, 1)
    end

    test "leading: is rejected inside a token body -- left-recursion-cycle detection is rule-level only" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        primary := "x"
        FOO := @native("M", "f", primary) @hint(leading: (primary))
        r := "x"
        """)

      assert error.message =~ "leading: is only meaningful for a rule-position @native(...)"
    end

    test "@hint's leading: may only name an already-declared @native dependency" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        primary := "x"
        other := "y"
        r := @native("M", "f", primary) @hint(leading: (other))
        """)

      assert error.message =~ "may only name a rule already listed as an @native(...) dependency"
    end
  end
end
