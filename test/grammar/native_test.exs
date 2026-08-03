defmodule Grammar.NativeTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp vm_grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.1 calculator"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  describe "calculator via the native backend matches VM output" do
    for input <- [
          "2 + 3 * 4",
          "2",
          "(2 + 3) * 4",
          "1 + 2 + 3 + 4 + 5",
          "3.5 * 2",
          "10 / 2 - 1",
          "((1 + 2) * (3 + 4))",
          "100"
        ] do
      test "#{inspect(input)}", %{} = _context do
        input = unquote(input)

        assert Native.Calculator.run(input) ==
                 Grammar.VM.run(vm_grammar(), input, Calculator.Actions)
      end
    end

    test "a grammar/action mismatch (bad input) yields a Ichor.Error, not a crash" do
      assert {:error, %Ichor.Error{}} = Native.Calculator.run("2 + ")
      assert {:error, %Ichor.Error{}} = Native.Calculator.run("not a number")
    end
  end

  describe "parse/1 (bare recognizer, no Ichor.Actions)" do
    test "returns the consumed token count and the raw capture tree" do
      assert {:ok, pos, raw_captures} = Native.Calculator.parse("2 + 3")
      assert Keyword.has_key?(raw_captures, :term)
      assert {:ok, tokens} = Native.Calculator.tokenize("2 + 3")
      assert pos == length(tokens)
    end
  end

  describe "tokenize/1" do
    test "maximal munch produces the same tokens the VM lexer would" do
      assert {:ok, tokens} = Native.Calculator.tokenize("2+3")
      assert Enum.map(tokens, & &1.name) == [:NUMBER, :ANON_1, :NUMBER]
      assert Enum.map(tokens, & &1.text) == ["2", "+", "3"]
    end
  end
end
