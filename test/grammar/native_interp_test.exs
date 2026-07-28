defmodule Grammar.Native.InterpTest do
  use ExUnit.Case, async: true

  defp vm_grammar do
    source = File.read!(Path.join(__DIR__, "../interp/interp.aether"))
    {:ok, grammar} = Aether.Parser.parse(source)
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: vm_grammar()}
  end

  describe "string interpolation: a token that recurses into a rule, both backends" do
    test "a string with no interpolation is just its own text", %{grammar: g} do
      source = "\"hello\""
      assert Native.Interp.run(source) == {:ok, "hello"}
      assert Grammar.VM.run(g, source, InterpTest.Actions) == {:ok, "hello"}
    end

    test "a single embedded expression is actually evaluated, not just captured as text", %{
      grammar: g
    } do
      source = "\"sum: \#{1+2+3}\""
      assert Native.Interp.run(source) == {:ok, "sum: 6"}
      assert Grammar.VM.run(g, source, InterpTest.Actions) == {:ok, "sum: 6"}
    end

    test "literal text before, between, and after embedded expressions", %{grammar: g} do
      source = "\"a\#{1}b\#{2+3}c\""
      assert Native.Interp.run(source) == {:ok, "a1b5c"}
      assert Grammar.VM.run(g, source, InterpTest.Actions) == {:ok, "a1b5c"}
    end

    test "an unterminated string fails to parse", %{grammar: g} do
      source = "\"never closes"
      assert {:error, _} = Native.Interp.run(source)
      assert {:error, _} = Grammar.VM.run(g, source, InterpTest.Actions)
    end

    test "an unterminated embedded expression fails to parse", %{grammar: g} do
      source = "\"broken \#{1+"
      assert {:error, _} = Native.Interp.run(source)
      assert {:error, _} = Grammar.VM.run(g, source, InterpTest.Actions)
    end
  end
end
