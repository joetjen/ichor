defmodule Regex.ActionsTest do
  use ExUnit.Case, async: true

  alias Grammar.IR
  alias Support.ExampleGrammars

  defp grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.7 regex"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: grammar()}
  end

  defp run(grammar, pattern), do: Grammar.VM.run(grammar, pattern, Regex.Actions)

  # Source-span metadata naturally differs between `Aether.Parser`'s own
  # `/pattern/` desugaring and this grammar's independent parse of the
  # same text, so structural comparison has to ignore it.
  defp strip(expr), do: Support.IRStrip.strip(expr)

  describe "the regex correctness check" do
    test "matches exactly what calculator's own /pattern/-desugared NUMBER token produces", %{
      grammar: g
    } do
      {:ok, calculator} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.1 calculator"))
      expected = strip(calculator.tokens[:NUMBER])

      assert {:ok, ir} = run(g, "\\d+(\\.\\d+)?")
      assert strip(ir) == expected
    end
  end

  describe "shorthand classes" do
    test "\\d becomes a DIGIT rule reference", %{grammar: g} do
      assert {:ok, ir} = run(g, "\\d")
      assert strip(ir) == IR.rule_ref(:DIGIT)
    end

    test "\\D (negated) becomes not-DIGIT then any", %{grammar: g} do
      assert {:ok, ir} = run(g, "\\D")
      assert strip(ir) == IR.seq([IR.not_pred(IR.rule_ref(:DIGIT)), IR.any()])
    end
  end

  describe "alternation" do
    test "a single alternative passes through unwrapped", %{grammar: g} do
      assert {:ok, ir} = run(g, "a")
      assert strip(ir) == IR.literal("a")
    end

    test "multiple alternatives become a Choice", %{grammar: g} do
      assert {:ok, ir} = run(g, "a|b|c")
      assert strip(ir) == IR.choice([IR.literal("a"), IR.literal("b"), IR.literal("c")])
    end
  end

  describe "quantifiers" do
    test "* + ? and exact/bounded repetition", %{grammar: g} do
      assert {:ok, ir} = run(g, "a*")
      assert strip(ir) == IR.star(IR.literal("a"))

      assert {:ok, ir} = run(g, "a+")
      assert strip(ir) == IR.plus(IR.literal("a"))

      assert {:ok, ir} = run(g, "a?")
      assert strip(ir) == IR.opt(IR.literal("a"))

      assert {:ok, ir} = run(g, "a{3}")
      assert strip(ir) == IR.rep(IR.literal("a"), 3, 3)

      assert {:ok, ir} = run(g, "a{3,}")
      assert strip(ir) == IR.rep(IR.literal("a"), 3, :infinity)

      assert {:ok, ir} = run(g, "a{3,7}")
      assert strip(ir) == IR.rep(IR.literal("a"), 3, 7)
    end
  end

  describe "groups and lookaheads" do
    test "a plain group is just its inner pattern", %{grammar: g} do
      assert {:ok, ir} = run(g, "(ab)")
      assert strip(ir) == IR.seq([IR.literal("a"), IR.literal("b")])
    end

    test "positive lookahead", %{grammar: g} do
      assert {:ok, ir} = run(g, "(?=a)")
      assert strip(ir) == IR.and_pred(IR.literal("a"))
    end

    test "negative lookahead", %{grammar: g} do
      assert {:ok, ir} = run(g, "(?!a)")
      assert strip(ir) == IR.not_pred(IR.literal("a"))
    end
  end

  describe "character classes" do
    test "a plain range", %{grammar: g} do
      assert {:ok, ir} = run(g, "[a-z]")
      assert strip(ir) == IR.char_class([{?a, ?z}])
    end

    test "a negated range", %{grammar: g} do
      assert {:ok, ir} = run(g, "[^a-z]")
      assert strip(ir) == IR.seq([IR.not_pred(IR.char_class([{?a, ?z}])), IR.any()])
    end

    test "multiple items: a range plus a bare char", %{grammar: g} do
      assert {:ok, ir} = run(g, "[a-z0]")
      assert strip(ir) == IR.char_class([{?a, ?z}, {?0, ?0}])
    end
  end

  describe "dot" do
    test ". becomes Any", %{grammar: g} do
      assert {:ok, ir} = run(g, ".")
      assert strip(ir) == IR.any()
    end
  end
end
