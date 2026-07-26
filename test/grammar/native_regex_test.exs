defmodule Grammar.Native.RegexTest do
  use ExUnit.Case, async: true

  alias Support.{ExampleGrammars, IRStrip}

  defp vm_grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.7 regex"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: vm_grammar()}
  end

  describe "run/1 parity with the VM backend (structural IR comparison)" do
    for pattern <- [
          "\\d+(\\.\\d+)?",
          "\\d",
          "\\D",
          "a",
          "a|b|c",
          "a*",
          "a+",
          "a?",
          "a{3}",
          "a{3,}",
          "a{3,7}",
          "(ab)",
          "(?=a)",
          "(?!a)",
          "[a-z]",
          "[^a-z]",
          "[a-z0]",
          "."
        ] do
      test "#{inspect(pattern)}", %{grammar: g} do
        pattern = unquote(pattern)

        assert {:ok, native_ir} = Native.Regex.run(pattern)
        assert {:ok, vm_ir} = Grammar.VM.run(g, pattern, Regex.Actions)
        assert IRStrip.strip(native_ir) == IRStrip.strip(vm_ir)
      end
    end
  end

  test "matches exactly what calculator's own /pattern/-desugared NUMBER token produces" do
    {:ok, calculator} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.1 calculator"))
    expected = IRStrip.strip(calculator.tokens[:NUMBER])

    assert {:ok, ir} = Native.Regex.run("\\d+(\\.\\d+)?")
    assert IRStrip.strip(ir) == expected
  end
end
