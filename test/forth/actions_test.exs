defmodule Forth.ActionsTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.8 forth"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: grammar()}
  end

  defp run(grammar, source),
    do: Grammar.VM.run(grammar, source, Forth.Actions, Forth.Actions.new_context())

  describe "the forth worked example" do
    test "a word definition, then invoking it computes dup * (squaring)", %{grammar: g} do
      assert {:ok, [25]} = run(g, ": square dup * ;\n5 square")
    end
  end

  describe "maximal munch: NUMBER wins the tie over WORD_NAME" do
    test "digit-shaped text lexes as NUMBER, not WORD_NAME", %{grammar: g} do
      assert {:ok, [5]} = run(g, "5")
    end

    test "a negative number", %{grammar: g} do
      assert {:ok, [-3]} = run(g, "-3")
    end
  end

  describe "native words" do
    test "+ - * /", %{grammar: g} do
      assert {:ok, [8]} = run(g, "5 3 +")
      assert {:ok, [2]} = run(g, "5 3 -")
      assert {:ok, [15]} = run(g, "5 3 *")
      assert {:ok, [2]} = run(g, "6 3 /")
    end

    test "dup drop swap", %{grammar: g} do
      assert {:ok, [5, 5]} = run(g, "5 dup")
      assert {:ok, []} = run(g, "5 drop")
      assert {:ok, [2, 1]} = run(g, "2 1 swap")
    end
  end

  describe "a flat program with no definitions" do
    test "bare numbers just accumulate on the stack", %{grammar: g} do
      assert {:ok, [3, 2, 1]} = run(g, "1 2 3")
    end
  end

  describe "word definitions store their body as thunks" do
    test "a word can be invoked more than once", %{grammar: g} do
      assert {:ok, [2, 2]} = run(g, ": two 2 ;\ntwo two")
    end

    test "a word never invoked has no effect at all", %{grammar: g} do
      assert {:ok, [1]} = run(g, ": never-called 1 0 / ;\n1")
    end
  end

  describe "errors" do
    test "an unbound word yields a Ichor.Error, not a crash", %{grammar: g} do
      assert {:error, %Ichor.Error{message: message}} = run(g, "unbound-word")
      assert message =~ "unbound word"
    end
  end
end
