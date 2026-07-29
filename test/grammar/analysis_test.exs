defmodule Grammar.AnalysisTest do
  use ExUnit.Case, async: true

  alias Grammar.Analysis
  alias Grammar.IR
  alias Support.MiniMatcher

  defp compile!(source) do
    {:ok, grammar} = Aether.Parser.parse(source)
    grammar
  end

  defp ok!(source) do
    case Analysis.run(compile!(source)) do
      {:ok, grammar} ->
        grammar

      {:error, errors} ->
        flunk(
          "expected analysis to pass, got:\n#{Enum.map_join(errors, "\n", &Ichor.Error.format/1)}"
        )
    end
  end

  defp fails(source) do
    case Analysis.run(compile!(source)) do
      {:error, errors} -> errors
      {:ok, _} -> flunk("expected analysis to fail")
    end
  end

  describe "the 9 worked example grammars all pass analysis cleanly" do
    for {name, _source} <- Support.ExampleGrammars.all() do
      test "#{name}" do
        source = Support.ExampleGrammars.all()[unquote(name)]
        assert {:ok, _grammar} = Analysis.run(compile!(source))
      end
    end
  end

  describe "left-recursion: direct case is rewritten to iterative IR and still parses correctly" do
    test "the classic expr := expr PLUS term | term shape" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root expr

        PLUS := "+"
        NUM  := /\d+/

        expr := expr PLUS NUM | NUM
        """)

      # rewritten shape: NUM (SPACE* PLUS SPACE* NUM)*, not the original self-reference
      assert %IR.Seq{exprs: [%IR.RuleRef{name: :NUM}, %IR.Star{expr: inner}]} =
               grammar.rules[:expr]

      assert %IR.Seq{exprs: exprs} = inner
      assert Enum.map(exprs, & &1.__struct__) == [IR.Star, IR.RuleRef, IR.Star, IR.RuleRef]
      assert Enum.find(exprs, &match?(%IR.RuleRef{name: :PLUS}, &1))
      assert Enum.find(exprs, &match?(%IR.RuleRef{name: :NUM}, &1))
      refute Enum.any?(IR.children(grammar.rules[:expr]), &match?(%IR.RuleRef{name: :expr}, &1))

      # and it actually parses the way the original grammar intended.
      assert MiniMatcher.matches?(grammar, :expr, "1")
      assert MiniMatcher.matches?(grammar, :expr, "1+2")
      assert MiniMatcher.matches?(grammar, :expr, "1+2+3+4")
      refute MiniMatcher.matches?(grammar, :expr, "")
      refute MiniMatcher.matches?(grammar, :expr, "1+")
      refute MiniMatcher.matches?(grammar, :expr, "+1")
    end

    test "a captured base case survives the rewrite untouched" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root expr

        PLUS := "+"
        NUM  := /\d+/

        expr := expr PLUS n:NUM | n:NUM
        """)

      assert MiniMatcher.matches?(grammar, :expr, "1+2+3")
    end

    test "with no base case at all, it's an error, not a bad rewrite" do
      errors =
        fails(~S"""
        @grammar "t"
        @root a
        X := "x"
        a := a X
        """)

      assert [error] = errors
      assert error.message =~ "no non-recursive alternative to serve as a base case"
    end

    test "a self-reference hidden behind a capture is not silently mis-rewritten" do
      errors =
        fails(~S"""
        @grammar "t"
        @root expr
        PLUS := "+"
        NUM  := /\d+/
        expr := lhs:(expr PLUS NUM) | NUM
        """)

      assert [error] = errors

      assert error.message =~ "not a direct, bare leading reference" or
               error.message =~ "isn't a direct, bare leading reference"
    end
  end

  describe "@engine lr/glr: left recursion is left alone, not rewritten or rejected" do
    test "a directly left-recursive rule (would be rewritten under :peg) passes through as-is" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root expr
        @engine glr

        PLUS := "+"
        NUM  := /\d+/

        expr := expr PLUS NUM | NUM
        """)

      assert %IR.Choice{exprs: [recursive, _base]} = grammar.rules[:expr]
      assert %IR.Seq{exprs: [%IR.RuleRef{name: :expr} | _]} = recursive
    end

    test "an indirect left-recursive cycle (an error under :peg) also passes through" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root a
        @engine lr
        X := "x"
        a := b X | X
        b := a X | X
        """)

      assert grammar.engine == :lr
    end
  end

  describe "left-recursion: indirect case is detected but not auto-rewritten" do
    test "a two-rule cycle is reported for both participants" do
      errors =
        fails(~S"""
        @grammar "t"
        @root a
        X := "x"
        a := b X | X
        b := a X | X
        """)

      messages = Enum.map(errors, & &1.message)
      assert Enum.any?(messages, &(&1 =~ "a is left-recursive"))
      assert Enum.any?(messages, &(&1 =~ "b is left-recursive"))
      assert Enum.all?(messages, &(&1 =~ "automatic rewriting only supports a direct"))
    end
  end

  describe "reference checks" do
    test "a dangling reference is reported with a precise location" do
      errors =
        fails(~S"""
        @grammar "t"
        @root r
        r := nope
        """)

      assert [error] = errors
      assert error.stage == :analysis
      assert error.message =~ "undefined token or rule :nope"
      assert error.line == 3
    end
  end

  describe "@native(...) dependency checks" do
    test "a dangling @native(...) dependency is reported, same as an ordinary dangling RuleRef" do
      errors =
        fails(~S"""
        @grammar "t"
        @root r
        r := @native("M", "f", nope)
        """)

      assert [error] = errors
      assert error.message =~ "@native(...) depends on undefined rule :nope"
    end

    # `nullable` feeds left-recursion rewriting's "does the remainder make
    # progress" check, not the (deliberately stricter) empty-repetition
    # lint -- a Custom node's `always_empty?` always answers `false`
    # (opaque code proving "unconditionally zero-width" statically isn't
    # possible; the runtime `test_progress` guard is the real safety net
    # for that hazard, same as for every other node kind).
    test "nullable: true makes a left-recursion rewrite's remainder-can't-be-empty check reject it" do
      errors =
        fails(~S"""
        @grammar "t"
        @root r
        @noskip
        r := r @native("M", "f") @hint(nullable: true) | "base"
        """)

      assert [error] = errors
      assert error.message =~ "would produce an infinite loop"
    end

    test "with nullable defaulting to false, the same left-recursion rewrite succeeds" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        @noskip
        r := r @native("M", "f") | "base"
        """)

      assert %IR.Seq{exprs: [%IR.RuleRef{}, %IR.Star{expr: %IR.Custom{}}]} = grammar.rules[:r]
    end

    test "with nullable defaulting to false, a Custom node wrapped in * is not flagged as an empty-repetition hazard" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        @noskip
        primary := "x"
        r := @native("M", "f", primary)*
        """)

      assert %IR.Star{expr: %IR.Custom{}} = grammar.rules[:r]
    end
  end

  describe "possibly-empty-match repetition" do
    # @noskip here specifically: under an active @skip, `X*` is itself
    # rewritten by `Aether.Parser` into a skip-separated repetition that
    # this static lint can no longer see through -- an
    # always-empty `X` stops looking always-empty once it's sitting next
    # to a `Star(skip_token)` that usually isn't. That's not a hole in
    # practice: `Grammar.VM.Compiler`'s `:test_progress` guard (see its
    # docs) stops the same hazard at runtime either way, skip-wrapped or
    # not. This lint's job is catching the direct, unwrapped case early.
    test "an unconditionally-empty token wrapped in * is rejected" do
      errors =
        fails(~S"""
        @grammar "t"
        @root r
        @noskip
        EMPTY := .{0}
        r := EMPTY*
        """)

      assert [error] = errors
      assert error.message =~ "unconditionally-empty match"
    end

    test "a bare predicate wrapped in * is rejected (the classic (!END)* footgun)" do
      errors =
        fails(~S"""
        @grammar "t"
        @root r
        @noskip
        END := "z"
        r := (!END)*
        """)

      assert [error] = errors
      assert error.message =~ "unconditionally-empty match"
    end

    test "under an active @skip, the same hazard is still safe at runtime (test_progress guard), even though the static lint can't see through the skip-rewrite" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        EMPTY := .{0}
        r := EMPTY*
        """)

      # doesn't hang, and doesn't blow up -- it just correctly matches
      # nothing, same as a real Star(always-empty) would mean.
      assert {:ok, 0} = Grammar.VM.parse(grammar, "")
    end

    test "a merely-nullable skip token is NOT flagged -- SPACE := [ \\t]* is completely ordinary" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        SPACE := [ \t]*
        FOO := "x"
        r := FOO FOO
        """)

      assert %IR.Star{expr: %IR.RuleRef{name: :SPACE}} =
               grammar.rules[:r] |> IR.children() |> Enum.at(1)
    end
  end

  describe "duplicate-alternative lint" do
    test "two structurally identical alternatives -- the second is dead code" do
      errors =
        fails(~S"""
        @grammar "t"
        @root r
        r := "a" | "a" | "b"
        """)

      assert [error] = errors
      assert error.message =~ "duplicates an earlier alternative"
      # points at the SECOND "a", not the first
      assert error.column > 10
    end

    test "structurally different alternatives with the same text length are not flagged" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        r := "a" | "b"
        """)

      assert %IR.Choice{} = grammar.rules[:r]
    end
  end
end
