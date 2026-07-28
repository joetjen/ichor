defmodule Grammar.GLRTest do
  use ExUnit.Case, async: true

  defp compile!(path) do
    source = File.read!(path)
    {:ok, grammar} = Aether.Parser.parse(source)
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  describe "the PEG greedy-commit-failure gap: rule := A A | A, top := rule A" do
    setup do
      {:ok,
       peg: compile!(Path.join(__DIR__, "../peg_gap/peg_gap_peg.aether")),
       glr: compile!(Path.join(__DIR__, "../peg_gap/peg_gap_glr.aether"))}
    end

    test "plain PEG (Grammar.VM) genuinely cannot parse \"aa\" -- rule greedily consumes both A's, leaving none for top",
         %{peg: peg} do
      assert {:error, _} = Grammar.VM.run(peg, "aa", PegGapTest.Actions)
    end

    test "Grammar.GLR parses the exact same grammar shape's \"aa\" by forking at rule's choice point",
         %{glr: glr} do
      assert Grammar.GLR.run(glr, "aa", PegGapTest.Actions) == {:ok, 1}
    end

    test "\"aaa\" only has one valid split (rule = AA, top's own trailing A) -- Grammar.GLR finds it",
         %{
           glr: glr
         } do
      assert Grammar.GLR.run(glr, "aaa", PegGapTest.Actions) == {:ok, 2}
    end

    test "input with no valid split at all is still a clean parse error, not a crash", %{glr: glr} do
      assert {:error, _} = Grammar.GLR.run(glr, "aaaa", PegGapTest.Actions)
      assert {:error, _} = Grammar.GLR.run(glr, "", PegGapTest.Actions)
    end

    test "the same rule shape, tagged @engine lr, is rejected for its real conflicts (not just the engine tag)" do
      source = ~S"""
      @grammar "t"
      @root top
      @engine lr
      @noskip

      A := "a"

      rule := A A | A
      top := rule A
      """

      {:ok, grammar} = Aether.Parser.parse(source)
      {:ok, grammar} = Grammar.Analysis.run(grammar)
      assert {:error, errors} = Grammar.LR.compile(grammar)
      assert Enum.any?(errors, &(&1.message =~ "conflict"))
    end
  end

  describe "declared-order tie-break on genuine ambiguity: s := a | b, a := X, b := X" do
    setup do
      {:ok, grammar: compile!(Path.join(__DIR__, "../ambig_tiebreak/ambig_tiebreak.aether"))}
    end

    test "the table has a real reduce/reduce conflict here", %{grammar: grammar} do
      {:ok, table} = Grammar.LRTable.build(grammar)
      assert Grammar.LRTable.conflicts(table) != []
    end

    test "a declared first in s's own alternatives -- Grammar.GLR picks the a-rooted derivation",
         %{
           grammar: grammar
         } do
      assert Grammar.GLR.run(grammar, "x", AmbigTiebreakTest.Actions) == {:ok, :picked_a}
    end
  end

  describe "the classic dangling-else ambiguity, a real one (C/Java/JavaScript/PHP), not an abstract textbook shape" do
    setup do
      {:ok, grammar: compile!(Path.join(__DIR__, "../dangling_else/dangling_else.aether"))}
    end

    test "the table has a real shift/reduce conflict here", %{grammar: grammar} do
      {:ok, table} = Grammar.LRTable.build(grammar)
      assert Grammar.LRTable.conflicts(table) != []
    end

    test "an unambiguous single if/else is unaffected", %{grammar: grammar} do
      assert Grammar.GLR.run(grammar, "if c then 1 else 2", DanglingElseTest.Actions) ==
               {:ok, {:if, :c, 1, 2}}
    end

    test "nested if/then/else -- the else attaches to the nearest (inner) if, matching every real language's own convention",
         %{grammar: grammar} do
      assert Grammar.GLR.run(grammar, "if c then if d then 1 else 2", DanglingElseTest.Actions) ==
               {:ok, {:if, :c, {:if, :d, 1, 2}, nil}}
    end

    test "a nested if with no else at all still parses cleanly", %{grammar: grammar} do
      assert Grammar.GLR.run(grammar, "if c then if d then 1", DanglingElseTest.Actions) ==
               {:ok, {:if, :c, {:if, :d, 1, nil}, nil}}
    end
  end

  describe "engine-mismatch guards" do
    test "Grammar.GLR refuses an @engine peg grammar" do
      grammar = compile!(Path.join(__DIR__, "../peg_gap/peg_gap_peg.aether"))
      assert {:error, [error]} = Grammar.GLR.compile(grammar)
      assert error.message =~ "@engine peg"
    end

    test "Grammar.LR refuses an @engine glr grammar" do
      grammar = compile!(Path.join(__DIR__, "../ambig_tiebreak/ambig_tiebreak.aether"))
      assert {:error, [error]} = Grammar.LR.compile(grammar)
      assert error.message =~ "@engine glr"
    end
  end
end
