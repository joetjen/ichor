defmodule Ichor.EBNF.ISO.ActionsTest do
  use ExUnit.Case, async: true
  doctest Ichor.EBNF.ISO

  alias Grammar.IR
  alias Support.IRStrip

  defp run(source), do: Ichor.EBNF.ISO.run(source)

  defp rule(source, name) do
    {:ok, ruleset} = run(source)
    Map.fetch!(ruleset, name)
  end

  describe "the ISO EBNF worked example" do
    test "digit/number, exercising comma-concatenation and { } repetition" do
      source = ~S"""
      digit = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;
      number = digit, { digit } ;
      """

      assert {:ok, ruleset} = run(source)

      assert IRStrip.strip(ruleset[:digit]) ==
               IRStrip.strip(IR.choice(for d <- ~w(0 1 2 3 4 5 6 7 8 9), do: IR.literal(d)))

      assert IRStrip.strip(ruleset[:number]) ==
               IRStrip.strip(IR.seq([IR.rule_ref(:digit), IR.star(IR.rule_ref(:digit))]))
    end
  end

  describe "terminal strings" do
    test "single- and double-quoted terminals" do
      assert IRStrip.strip(rule(~S(a = 'x', "y" ;), :a)) ==
               IRStrip.strip(IR.seq([IR.literal("x"), IR.literal("y")]))
    end
  end

  describe "the exception operator (best-effort, see moduledoc)" do
    test "the nonzero_digit exception-operator example" do
      assert IRStrip.strip(rule(~S(nonzero = digit - "0" ;), :nonzero)) ==
               IRStrip.strip(IR.seq([IR.not_pred(IR.literal("0")), IR.rule_ref(:digit)]))
    end
  end

  describe "optional_seq, repeated_seq, grouped_seq" do
    test "[ ... ] becomes Opt" do
      assert IRStrip.strip(rule(~S(sign = [ "+" | "-" ] ;), :sign)) ==
               IRStrip.strip(IR.opt(IR.choice([IR.literal("+"), IR.literal("-")])))
    end

    test "{ ... } becomes Star" do
      assert IRStrip.strip(rule(~S(as = { "a" } ;), :as)) ==
               IRStrip.strip(IR.star(IR.literal("a")))
    end

    test "( ... ) is just grouping, no semantic change" do
      assert IRStrip.strip(rule(~S[x = ("a" | "b"), "c" ;], :x)) ==
               IRStrip.strip(
                 IR.seq([IR.choice([IR.literal("a"), IR.literal("b")]), IR.literal("c")])
               )
    end
  end

  describe "repeat_count (n * primary)" do
    test "an exact repetition count" do
      assert IRStrip.strip(rule(~S(aaa = 3 * "a" ;), :aaa)) ==
               IRStrip.strip(IR.rep(IR.literal("a"), 3, 3))
    end
  end

  describe "empty alternatives (a real framework-level finding, see moduledoc)" do
    test "a rule whose entire body is empty" do
      assert IRStrip.strip(rule("empty = ;\n", :empty)) == IRStrip.strip(IR.literal(""))
    end

    test "an empty alternative alongside a real one" do
      assert IRStrip.strip(rule(~S(x = "a" | ;), :x)) ==
               IRStrip.strip(IR.choice([IR.literal("a"), IR.literal("")]))
    end

    test "an empty alternative nested inside a grouped_seq" do
      assert IRStrip.strip(rule(~S[x = ("a" | ) ;], :x)) ==
               IRStrip.strip(IR.choice([IR.literal("a"), IR.literal("")]))
    end
  end

  describe "special_sequence (? ... ?)" do
    test "has no executable meaning, so it's a real error, not silently accepted" do
      assert {:error, %Ichor.Error{message: message}} = run("x = ? some text ? ;\n")
      assert message =~ "special sequence"
    end
  end

  describe "meta-identifiers" do
    test "multi-word identifiers (an embedded literal space) are preserved" do
      {:ok, ruleset} = run(~S(syntax rule = "a" ;) <> "\n")
      assert Map.has_key?(ruleset, :"syntax rule")
    end

    test "a rule referencing another rule" do
      assert IRStrip.strip(rule(~S(a = b ;), :a)) == IRStrip.strip(IR.rule_ref(:b))
    end
  end

  describe "comments (pure trivia, fully skippable)" do
    test "a comment before the first rule doesn't break parsing" do
      source = "(* a leading comment *)\ndigit = \"0\" ;\n"
      assert {:ok, ruleset} = run(source)
      assert IRStrip.strip(ruleset[:digit]) == IRStrip.strip(IR.literal("0"))
    end

    test "a comment between rules doesn't merge them" do
      source = "a = \"x\" ;\n(* a comment *)\nb = \"y\" ;\n"
      assert {:ok, ruleset} = run(source)
      assert IRStrip.strip(ruleset[:a]) == IRStrip.strip(IR.literal("x"))
      assert IRStrip.strip(ruleset[:b]) == IRStrip.strip(IR.literal("y"))
    end
  end

  describe "multiple rules stay separate (ISO EBNF's explicit BAR/COMMA separators avoid BNF's rule-swallowing bug by construction)" do
    test "two consecutive rules" do
      source = "a = \"x\" ;\nb = a ;\n"
      assert {:ok, ruleset} = run(source)
      assert IRStrip.strip(ruleset[:a]) == IRStrip.strip(IR.literal("x"))
      assert IRStrip.strip(ruleset[:b]) == IRStrip.strip(IR.rule_ref(:a))
    end

    test "a trailing newline (or lack of one) doesn't affect the result" do
      assert {:ok, with_nl} = run(~S(a = "x" ;) <> "\n")
      assert {:ok, without_nl} = run(~S(a = "x" ;))
      assert IRStrip.strip(with_nl[:a]) == IRStrip.strip(without_nl[:a])
    end
  end

  describe "duplicate definitions" do
    test "defining the same meta-identifier twice is a real error" do
      source = ~S"""
      a = "x" ;
      a = "y" ;
      """

      assert {:error, %Ichor.Error{message: message}} = run(source)
      assert message =~ "defined more than once"
    end
  end

  describe "fails informatively, not silently, on W3C-only syntax" do
    test "?/*/+ suffix quantifiers (ISO EBNF has no postfix quantifiers at all)" do
      assert {:error, %Ichor.Error{} = error} = run("x ::= [a-z]+\n")
      assert error.line && error.column
    end

    test "::= (ISO EBNF uses a bare =)" do
      assert {:error, %Ichor.Error{}} = run("x ::= \"a\"\n")
    end
  end

  describe "parse/1 and tokenize/1 (bare recognizer, generated by use Ichor)" do
    test "parse/1 matches with no Ichor.EBNF.ISO.Actions involved" do
      assert {:ok, _pos, _raw_captures} = Ichor.EBNF.ISO.parse(~S(a = "x" ;))
    end

    test "tokenize/1 exposes the raw token stream" do
      assert {:ok, tokens} = Ichor.EBNF.ISO.tokenize(~S(a = "x" ;))

      assert Enum.map(tokens, & &1.name) == [
               :IDENT,
               :EQUALS,
               :TRIVIA,
               :DQ_TERMINAL,
               :TRIVIA,
               :SEMI
             ]
    end
  end
end
