defmodule Ichor.PEG.ActionsTest do
  use ExUnit.Case, async: true
  doctest Ichor.PEG

  alias Grammar.IR
  alias Support.IRStrip

  defp run(source), do: Ichor.PEG.run(source)

  defp rule(source, name) do
    {:ok, ruleset} = run(source)
    Map.fetch!(ruleset, name)
  end

  describe "the worked example" do
    test "digit/number: PLUS on a plain rule reference" do
      assert {:ok, ruleset} = run("digit  <- [0-9]\nnumber <- digit+\n")
      assert IRStrip.strip(ruleset[:digit]) == IRStrip.strip(IR.char_class([{?0, ?9}]))
      assert IRStrip.strip(ruleset[:number]) == IRStrip.strip(IR.plus(IR.rule_ref(:digit)))
    end
  end

  describe "literals" do
    test "single- and double-quoted literals" do
      assert IRStrip.strip(rule(~S[a <- 'x' "y"], :a)) ==
               IRStrip.strip(IR.seq([IR.literal("x"), IR.literal("y")]))
    end
  end

  describe "ordered choice and sequence" do
    test "a single alternative isn't wrapped in Choice" do
      assert IRStrip.strip(rule("a <- b\n", :a)) == IRStrip.strip(IR.rule_ref(:b))
    end

    test "multiple alternatives become a Choice, in source order" do
      assert IRStrip.strip(rule("a <- b / c / d\n", :a)) ==
               IRStrip.strip(IR.choice([IR.rule_ref(:b), IR.rule_ref(:c), IR.rule_ref(:d)]))
    end

    test "multiple prefixes become a Seq, in source order" do
      assert IRStrip.strip(rule("a <- b c d\n", :a)) ==
               IRStrip.strip(IR.seq([IR.rule_ref(:b), IR.rule_ref(:c), IR.rule_ref(:d)]))
    end
  end

  describe "and/not predicates" do
    test "&expr (positive lookahead)" do
      assert IRStrip.strip(rule("a <- &b\n", :a)) == IRStrip.strip(IR.and_pred(IR.rule_ref(:b)))
    end

    test "!expr (negative lookahead)" do
      assert IRStrip.strip(rule("a <- !b\n", :a)) == IRStrip.strip(IR.not_pred(IR.rule_ref(:b)))
    end

    test "combined with a following sequence element" do
      assert IRStrip.strip(rule("a <- &b !c d\n", :a)) ==
               IRStrip.strip(
                 IR.seq([
                   IR.and_pred(IR.rule_ref(:b)),
                   IR.not_pred(IR.rule_ref(:c)),
                   IR.rule_ref(:d)
                 ])
               )
    end
  end

  describe "quantifiers" do
    test "?/*/+ all in one sequence" do
      assert IRStrip.strip(rule("a <- b? c* d+\n", :a)) ==
               IRStrip.strip(
                 IR.seq([
                   IR.opt(IR.rule_ref(:b)),
                   IR.star(IR.rule_ref(:c)),
                   IR.plus(IR.rule_ref(:d))
                 ])
               )
    end
  end

  describe "grouping" do
    test "(...) groups without changing meaning" do
      assert IRStrip.strip(rule("a <- (b / c) d\n", :a)) ==
               IRStrip.strip(
                 IR.seq([IR.choice([IR.rule_ref(:b), IR.rule_ref(:c)]), IR.rule_ref(:d)])
               )
    end
  end

  describe "char classes" do
    test "a single range" do
      assert IRStrip.strip(rule("a <- [a-z]\n", :a)) == IRStrip.strip(IR.char_class([{?a, ?z}]))
    end

    test "adjacent ranges with no separator stay distinct" do
      assert IRStrip.strip(rule("a <- [a-zA-Z0-9]\n", :a)) ==
               IRStrip.strip(IR.char_class([{?a, ?z}, {?A, ?Z}, {?0, ?9}]))
    end

    test "negation (^)" do
      assert IRStrip.strip(rule("a <- [^a-z]\n", :a)) ==
               IRStrip.strip(IR.seq([IR.not_pred(IR.char_class([{?a, ?z}])), IR.any()]))
    end
  end

  describe "dot" do
    test ". becomes Any" do
      assert IRStrip.strip(rule("a <- .\n", :a)) == IRStrip.strip(IR.any())
    end
  end

  describe "the IDENT !ARROW disambiguation (this format's own key finding)" do
    test "a bare identifier reference resolves as a reference, not a new rule" do
      assert IRStrip.strip(rule("a <- b\nb <- 'x'\n", :a)) == IRStrip.strip(IR.rule_ref(:b))
    end

    test "two consecutive rules stay separate -- no explicit newline-splitting needed here" do
      source = "foo <- bar\nbaz <- qux\n"
      assert {:ok, ruleset} = run(source)
      assert IRStrip.strip(ruleset[:foo]) == IRStrip.strip(IR.rule_ref(:bar))
      assert IRStrip.strip(ruleset[:baz]) == IRStrip.strip(IR.rule_ref(:qux))
    end

    test "digit+ referencing another rule doesn't get confused with a new rule definition" do
      assert {:ok, ruleset} = run("digit <- [0-9]\nnumber <- digit+\nother <- number\n")
      assert IRStrip.strip(ruleset[:number]) == IRStrip.strip(IR.plus(IR.rule_ref(:digit)))
      assert IRStrip.strip(ruleset[:other]) == IRStrip.strip(IR.rule_ref(:number))
    end
  end

  describe "comments and edge cases" do
    test "a leading comment doesn't break parsing" do
      source = "# leading comment\na <- 'x'\n"
      assert {:ok, ruleset} = run(source)
      assert IRStrip.strip(ruleset[:a]) == IRStrip.strip(IR.literal("x"))
    end

    test "a trailing newline (or lack of one) doesn't affect the result" do
      assert {:ok, with_nl} = run("a <- 'x'\n")
      assert {:ok, without_nl} = run("a <- 'x'")
      assert IRStrip.strip(with_nl[:a]) == IRStrip.strip(without_nl[:a])
    end

    test "an empty sequence (a rule with no elements) matches epsilon" do
      assert IRStrip.strip(rule("a <- \n", :a)) == IRStrip.strip(IR.literal(""))
    end
  end

  describe "duplicate definitions" do
    test "defining the same rule twice is a real error" do
      source = "a <- 'x'\na <- 'y'\n"
      assert {:error, %Ichor.Error{message: message}} = run(source)
      assert message =~ "defined more than once"
    end
  end

  describe "parse/1 and tokenize/1 (bare recognizer, generated by use Ichor)" do
    test "parse/1 matches with no Ichor.PEG.Actions involved" do
      assert {:ok, _pos, _raw_captures} = Ichor.PEG.parse("a <- 'x'\n")
    end

    test "tokenize/1 exposes the raw token stream, including a whole char class as one token" do
      assert {:ok, tokens} = Ichor.PEG.tokenize("a <- [a-z]\n")

      assert Enum.map(tokens, & &1.name) == [
               :IDENT,
               :TRIVIA,
               :ARROW,
               :TRIVIA,
               :CHAR_CLASS,
               :TRIVIA
             ]
    end
  end
end
