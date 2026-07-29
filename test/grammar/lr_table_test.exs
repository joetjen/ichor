defmodule Grammar.LRTableTest do
  use ExUnit.Case, async: true

  alias Grammar.LRTable.{Builder, Desugar, Production}

  defp compile!(source, opts \\ []) do
    {:ok, grammar} = Aether.Parser.parse(source)

    if Keyword.get(opts, :analyze, true) do
      {:ok, grammar} = Grammar.Analysis.run(grammar)
      grammar
    else
      grammar
    end
  end

  describe "Desugar: flattening PEG IR into CFG productions" do
    test "a left-recursive rule is preserved, not rewritten -- @engine skips that pass" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root expr
        @engine glr
        @noskip

        PLUS := "+"
        NUM  := "1"

        expr := expr PLUS n:NUM | n:NUM
        """)

      {:ok, productions} = Desugar.run(grammar)
      expr_prods = Enum.filter(productions, &(&1.lhs == :expr))

      assert [
               %Production{
                 rhs: [{:nonterminal, :expr}, {:terminal, :PLUS}, {:terminal, :NUM}],
                 captures: [{0, :expr, :rule}, {1, :PLUS, :token}, {2, :n, :token}]
               },
               %Production{rhs: [{:terminal, :NUM}], captures: [{0, :n, :token}]}
             ] = expr_prods
    end

    test "a bare RuleRef to an anon (auto-promoted) literal token gets no capture entry" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root r
        @engine glr
        @noskip
        NUM := "1"
        r := NUM "+" NUM
        """)

      {:ok, productions} = Desugar.run(grammar)
      [r_prod] = Enum.filter(productions, &(&1.lhs == :r))

      assert length(r_prod.rhs) == 3
      assert r_prod.captures == [{0, :NUM, :token}, {2, :NUM, :token}]
    end

    test "a bare Star produces a left-recursive helper nonterminal, spliced (not wrapped) into the caller" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root program
        @engine glr
        @noskip
        WORD := "a"
        item := WORD
        program := item item*
        """)

      {:ok, productions} = Desugar.run(grammar)
      [program_prod] = Enum.filter(productions, &(&1.lhs == :program))

      assert [{:nonterminal, :item}, {:nonterminal, helper}] = program_prod.rhs
      assert program_prod.captures == [{0, :item, :rule}, {1, nil, :splice}]

      helper_prods = Enum.filter(productions, &(&1.lhs == helper))
      assert Enum.any?(helper_prods, &(&1.rhs == []))
      assert Enum.any?(helper_prods, &match?({:nonterminal, ^helper}, List.first(&1.rhs)))
    end

    test "a captured composite (not a bare RuleRef) becomes a :text-kind span capture" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root r
        @engine glr
        @noskip
        A := "a"
        B := "b"
        r := x:(A B)
        """)

      {:ok, productions} = Desugar.run(grammar)
      [r_prod] = Enum.filter(productions, &(&1.lhs == :r))

      assert [{:nonterminal, _helper}] = r_prod.rhs
      assert r_prod.captures == [{0, :x, :text}]
    end

    test "@engine lr/glr rejects rule-level constructs LR can't table-compile" do
      grammar =
        compile!(
          ~S"""
          @grammar "t"
          @root r
          @engine glr
          @noskip
          A := "a"
          r := &A "x"
          """,
          analyze: false
        )

      {:ok, grammar} = Grammar.Analysis.run(grammar)
      assert {:error, [error]} = Desugar.run(grammar)
      assert error.message =~ "&predicate"
    end
  end

  describe "Grammar.LRTable.Builder.build/1: automaton + SLR(1) table" do
    test "a left-recursive, unambiguous grammar builds with zero conflicts" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root expr
        @engine lr

        PLUS := "+"
        NUM  := /\d+/

        expr := expr PLUS n:NUM | n:NUM
        """)

      assert {:ok, table} = Builder.build(grammar)
      assert Builder.conflicts(table) == []
    end

    test "a genuinely ambiguous grammar (two rules matching the same input) reports a reduce/reduce conflict" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root s
        @engine glr
        @noskip

        X := "x"

        s := a | b
        a := X
        b := X
        """)

      assert {:ok, table} = Builder.build(grammar)
      assert [{_state, _symbol, actions}] = Builder.conflicts(table)
      assert length(actions) == 2
    end

    test "the classic PEG greedy-commit-failure shape is a real reduce/reduce conflict here" do
      grammar =
        compile!(~S"""
        @grammar "t"
        @root top
        @engine glr
        @skip SP

        A  := "a"
        SP := " "

        rule := A A | A
        top := rule A
        """)

      assert {:ok, table} = Builder.build(grammar)
      assert Builder.conflicts(table) != []
    end
  end
end
