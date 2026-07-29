defmodule Aether.EvalTest do
  use ExUnit.Case, async: true

  alias Aether.{Eval, Reader}
  alias Grammar.IR

  defp ok!(source) do
    case Reader.read(source) do
      {:ok, reader_grammar} ->
        case Eval.build(reader_grammar) do
          {:ok, grammar} ->
            grammar

          {:error, error} ->
            flunk("expected #{inspect(source)} to build, got:\n#{Ichor.Error.format(error)}")
        end

      {:error, error} ->
        flunk("expected #{inspect(source)} to read, got:\n#{Ichor.Error.format(error)}")
    end
  end

  defp fails(source) do
    {:ok, reader_grammar} = Reader.read(source)

    case Eval.build(reader_grammar) do
      {:error, error} -> error
      {:ok, _} -> flunk("expected #{inspect(source)} to fail to build")
    end
  end

  describe "desugaring" do
    test "an inline rule-body string literal gets promoted to an anonymous token" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        r := "hello"
        """)

      assert %IR.RuleRef{name: anon} = grammar.rules[:r]
      assert MapSet.member?(grammar.anon_tokens, anon)
      assert %IR.Literal{value: "hello"} = grammar.tokens[anon]
    end

    test "the same literal seen twice reuses the same anonymous token" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        r := "x" | "x"
        """)

      assert %IR.Choice{exprs: [%IR.RuleRef{name: a}, %IR.RuleRef{name: b}]} = grammar.rules[:r]
      assert a == b
    end

    test "a character class desugars into Grammar.IR" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        FOO := [a-z]
        r := FOO
        """)

      assert %IR.CharClass{ranges: [{?a, ?z}]} = grammar.tokens[:FOO]
    end

    test "a POSIX class item marks the underlying predefined token used" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        FOO := [[:digit:]]
        DIGIT := [0-9]
        r := FOO
        """)

      assert error.message =~ "cannot override DIGIT"
    end

    test "a /pattern/ regex literal desugars into Grammar.IR" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        NUMBER := /ab/
        r := NUMBER
        """)

      assert %IR.Seq{
               exprs: [
                 %IR.Literal{value: "a"},
                 %IR.Literal{value: "b"}
               ]
             } = grammar.tokens[:NUMBER]
    end
  end

  describe "@skip splicing" do
    test "a multi-term rule sequence gets SPACE* auto-spliced under the default @skip" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        A := "a"
        B := "b"
        r := A B
        """)

      assert %IR.Seq{exprs: [%IR.RuleRef{name: :A}, %IR.Star{}, %IR.RuleRef{name: :B}]} =
               grammar.rules[:r]
    end

    test "@noskip leaves a multi-term sequence unspliced" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        @noskip
        A := "a"
        B := "b"
        r := A B
        """)

      assert %IR.Seq{exprs: [%IR.RuleRef{name: :A}, %IR.RuleRef{name: :B}]} = grammar.rules[:r]
    end
  end

  describe "@native(...)/@hint(...) hint defaults" do
    test "with no @hint, nullable defaults to false and leading defaults to the deps list" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        primary := "x"
        r := @native("M", "f", primary)
        """)

      assert %IR.Custom{
               module: M,
               function: :f,
               deps: [:primary],
               nullable: false,
               leading: [:primary]
             } =
               grammar.rules[:r]
    end

    test "an explicit @hint overrides both defaults" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        primary := "x"
        r := @native("M", "f", primary) @hint(nullable: true, leading: ())
        """)

      assert %IR.Custom{nullable: true, leading: []} = grammar.rules[:r]
    end

    test "the module string resolves to a real module reference" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        primary := "x"
        r := @native("Prolog.Operators", "parse_infix", primary)
        """)

      assert %IR.Custom{module: Prolog.Operators, function: :parse_infix} = grammar.rules[:r]
    end
  end

  describe "validation" do
    test "@root naming an undefined rule is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root missing
        r := "a"
        """)

      assert error.message =~ "@root names undefined rule"
    end

    test "@skip naming an undefined token is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        @skip MISSING
        r := "a"
        """)

      assert error.message =~ "@skip names undefined token"
    end
  end
end
