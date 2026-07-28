defmodule Grammar.Native.KeywordsTest do
  use ExUnit.Case, async: true

  defp vm_grammar do
    source = File.read!(Path.join(__DIR__, "../keywords/keywords.aether"))
    {:ok, grammar} = Aether.Parser.parse(source)
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: vm_grammar()}
  end

  describe "@keywords: a plain table lookup on a token's own text" do
    test "native: if/return reclassify, other words don't", %{grammar: _g} do
      assert Native.Keywords.run("if x return 5") ==
               {:ok, [:if, {:ident, "x"}, :return, {:num, 5}]}
    end

    test "vm: if/return reclassify, other words don't", %{grammar: g} do
      assert Grammar.VM.run(g, "if x return 5", KeywordsTest.Actions) ==
               {:ok, [:if, {:ident, "x"}, :return, {:num, 5}]}
    end
  end

  describe "@refine: JS-style regex-vs-division lookbehind" do
    test "native: a slash right after a number is division", %{grammar: _g} do
      assert Native.Keywords.run("5 / 2") == {:ok, [{:num, 5}, :div, {:num, 2}]}
    end

    test "vm: a slash right after a number is division", %{grammar: g} do
      assert Grammar.VM.run(g, "5 / 2", KeywordsTest.Actions) ==
               {:ok, [{:num, 5}, :div, {:num, 2}]}
    end

    test "native: a slash right after an identifier is division", %{grammar: _g} do
      assert Native.Keywords.run("x / 2") == {:ok, [{:ident, "x"}, :div, {:num, 2}]}
    end

    test "vm: a slash right after an identifier is division", %{grammar: g} do
      assert Grammar.VM.run(g, "x / 2", KeywordsTest.Actions) ==
               {:ok, [{:ident, "x"}, :div, {:num, 2}]}
    end

    test "native: a slash right after `return` starts an expression, not division", %{
      grammar: _g
    } do
      assert Native.Keywords.run("return / 2") == {:ok, [:return, :regex_start, {:num, 2}]}
    end

    test "vm: a slash right after `return` starts an expression, not division", %{grammar: g} do
      assert Grammar.VM.run(g, "return / 2", KeywordsTest.Actions) ==
               {:ok, [:return, :regex_start, {:num, 2}]}
    end

    test "native: a slash with nothing before it starts an expression", %{grammar: _g} do
      assert Native.Keywords.run("/ 2") == {:ok, [:regex_start, {:num, 2}]}
    end

    test "vm: a slash with nothing before it starts an expression", %{grammar: g} do
      assert Grammar.VM.run(g, "/ 2", KeywordsTest.Actions) == {:ok, [:regex_start, {:num, 2}]}
    end
  end
end
