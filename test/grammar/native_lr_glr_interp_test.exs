defmodule Grammar.NativeLRGLRInterpTest do
  @moduledoc """
  Proves a `Grammar.IR.CustomLexeme` dependency (`STRING`'s `@native(...)`
  re-lexing into `expr`) works under `Grammar.Native.LR`/`.GLR`, not just
  the PEG backends: `Grammar.Native.RuleCompiler`'s ordinary per-rule
  functions get spliced in alongside the compiled LR/GLR parser, unused
  by `parse`/`run` themselves, present only so `JS.StringInterp`'s own
  `rule_matchers.expr` reference resolves.
  """

  use ExUnit.Case, async: true

  describe "@engine lr, compiled: a token that recurses into a rule" do
    test "a string with no interpolation is just its own text" do
      assert Native.InterpLR.run("\"hello\"") == {:ok, "hello"}
    end

    test "a single embedded expression is actually evaluated, not just captured as text" do
      assert Native.InterpLR.run("\"sum: \#{1+2+3}\"") == {:ok, "sum: 6"}
    end

    test "literal text before, between, and after embedded expressions" do
      assert Native.InterpLR.run("\"a\#{1+1}b\#{2+2}c\"") == {:ok, "a2b4c"}
    end
  end

  describe "@engine glr, compiled: the same CustomLexeme dependency" do
    test "a string with no interpolation is just its own text" do
      assert Native.InterpGLR.run("\"hello\"") == {:ok, "hello"}
    end

    test "a single embedded expression is actually evaluated, not just captured as text" do
      assert Native.InterpGLR.run("\"sum: \#{1+2+3}\"") == {:ok, "sum: 6"}
    end
  end
end
