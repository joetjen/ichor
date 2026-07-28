defmodule Grammar.VMTest do
  use ExUnit.Case, async: true

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

  describe "the calculator grammar end to end, with no Ichor.Actions" do
    setup do
      {:ok, grammar: compile!(@calculator)}
    end

    test "a single number", %{grammar: g} do
      assert {:ok, 1} = Grammar.VM.parse(g, "2")
    end

    test "left-to-right chained addition", %{grammar: g} do
      assert {:ok, _} = Grammar.VM.parse(g, "1 + 2 + 3 + 4 + 5")
    end

    test "precedence: * binds tighter than + (still just a recognizer, but must fully consume)",
         %{grammar: g} do
      assert {:ok, _} = Grammar.VM.parse(g, "2 + 3 * 4")
    end

    test "parenthesized groups", %{grammar: g} do
      assert {:ok, _} = Grammar.VM.parse(g, "(2 + 3) * 4")
    end

    test "decimals", %{grammar: g} do
      assert {:ok, _} = Grammar.VM.parse(g, "3.5 * 2")
    end

    test "empty input does not match expr", %{grammar: g} do
      assert {:error, error} = Grammar.VM.parse(g, "")
      assert error.message =~ "does not match"
    end

    test "trailing operator with nothing after it is rejected, pointing at the dangling operator",
         %{grammar: g} do
      assert {:error, error} = Grammar.VM.parse(g, "2 + ")
      assert error.message =~ "unexpected"
      assert error.column == 3
    end

    test "trailing garbage after a complete expression is rejected", %{grammar: g} do
      assert {:error, error} = Grammar.VM.parse(g, "2 +")
      assert error.message =~ "unexpected"
    end
  end

  describe "maximal munch" do
    test "the longer token wins even when the shorter one is listed first in the rule" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root r
        LPAREN        := "("
        LOOKAHEAD_POS := "(?="
        r := LPAREN | LOOKAHEAD_POS
        """)

      assert {:ok, 1} = Grammar.VM.parse(grammar, "(?=")
      assert {:ok, 1} = Grammar.VM.parse(grammar, "(")
    end

    test "equal-length matches break ties by declaration order" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root r
        NUMBER := /\d/
        WORD   := (!":" .)
        r := NUMBER
        """)

      # WORD would also match "5" (one char); NUMBER, declared first, must win
      # the tie for `r` (which only accepts NUMBER) to succeed at all.
      assert {:ok, 1} = Grammar.VM.parse(grammar, "5")
    end
  end

  describe "left recursion rewrite, exercised through the real VM (not just the mini matcher)" do
    test "expr := expr PLUS NUM | NUM parses left-to-right chains" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root expr
        PLUS := "+"
        NUM  := /\d+/
        expr := expr PLUS NUM | NUM
        """)

      assert {:ok, _} = Grammar.VM.parse(grammar, "1")
      assert {:ok, _} = Grammar.VM.parse(grammar, "1+2")
      assert {:ok, _} = Grammar.VM.parse(grammar, "1+2+3+4")
      assert {:error, _} = Grammar.VM.parse(grammar, "")
      assert {:error, _} = Grammar.VM.parse(grammar, "+1")
    end
  end

  describe "predicates" do
    test "negative lookahead: consume anything up to a terminator without consuming the terminator" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root r
        @noskip
        END  := ";"
        BODY := (!END .)+
        r := BODY END
        """)

      assert {:ok, _} = Grammar.VM.parse(grammar, "hello;")
      assert {:error, _} = Grammar.VM.parse(grammar, "hello")
    end

    test "positive lookahead consumes nothing itself" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root r
        @noskip
        A := "a"
        B := "b"
        r := &A A B
        """)

      assert {:ok, _} = Grammar.VM.parse(grammar, "ab")
      assert {:error, _} = Grammar.VM.parse(grammar, "xb")
    end
  end

  describe "bounded repetition" do
    test "{1,3} accepts one to three, not more" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root r
        @noskip
        D := [0-9]
        r := D{1,3}
        """)

      assert {:ok, _} = Grammar.VM.parse(grammar, "1")
      assert {:ok, _} = Grammar.VM.parse(grammar, "12")
      assert {:ok, _} = Grammar.VM.parse(grammar, "123")
      assert {:error, _} = Grammar.VM.parse(grammar, "1234")
    end

    test "{2,} requires at least two" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root r
        @noskip
        D := [0-9]
        r := D{2,}
        """)

      assert {:error, _} = Grammar.VM.parse(grammar, "1")
      assert {:ok, _} = Grammar.VM.parse(grammar, "12")
      assert {:ok, _} = Grammar.VM.parse(grammar, "123456")
    end
  end

  describe "@indent / @samecol" do
    # KEY/SCALAR deliberately don't overlap (letters vs. digits) -- this
    # is exercising @indent/@samecol specifically, not the separate
    # question of how global maximal munch behaves when two token
    # definitions *do* overlap (as the real YAML grammar's KEY/SCALAR
    # definitions -- `(!":" !"\n" .)+` and `(!"\n" .)+` -- do: SCALAR
    # would out-munch KEY on a whole "key: value" line, since it's
    # strictly longer at that position. That's a real open question for
    # any YAML grammar built this way, not a bug in @indent/@samecol
    # itself, which is all this test is checking.
    @indent_grammar ~S"""
    @grammar "t"
    @root doc
    @skip INLINE_WS

    KEY       := [a-z]+
    COLON     := ":"
    NEWLINE   := "\n"
    INLINE_WS := [ \t]*
    SCALAR    := [0-9]+

    doc  := @indent( pair (NEWLINE @samecol pair)* )
    pair := KEY COLON SCALAR
    """

    test "two pairs at the same column match" do
      grammar = compile!(@indent_grammar)
      assert {:ok, _} = Grammar.VM.parse(grammar, "a: 1\nb: 2")
    end

    test "a second line indented differently than the first is rejected" do
      grammar = compile!(@indent_grammar)
      assert {:error, _} = Grammar.VM.parse(grammar, "a: 1\n  b: 2")
    end
  end

  describe "@engine mismatch guard" do
    @glr_grammar ~S"""
    @grammar "t"
    @root r
    @engine glr
    r := "a"
    """

    test "Grammar.VM refuses to run a grammar tagged @engine glr" do
      grammar = compile!(@glr_grammar)
      assert {:error, error} = Grammar.VM.parse(grammar, "a")
      assert error.message =~ "@engine glr"
      assert error.message =~ "Grammar.LR/Grammar.GLR"
    end

    test "Grammar.VM.run_sequence/4 refuses it too" do
      grammar = compile!(@glr_grammar)
      assert {:error, error} = Grammar.VM.run_sequence(grammar, "a", Calculator.Actions, nil)
      assert error.message =~ "@engine glr"
    end
  end
end
