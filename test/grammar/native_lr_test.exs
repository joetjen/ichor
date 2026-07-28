defmodule Grammar.NativeLRTest do
  use ExUnit.Case, async: true

  defp lr_grammar do
    source = File.read!(Path.join(__DIR__, "../lr_calculator/lr_calculator.aether"))
    {:ok, grammar} = Aether.Parser.parse(source)
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: lr_grammar()}
  end

  # Native.LrCalculator (Grammar.Native.LR, per-state compiled dispatch)
  # against the exact same fixture the interpreted Grammar.LR and
  # Grammar.VM tests already trust -- three engines, one grammar shape,
  # identical results.
  for {input, expected} <- [
        {"2+3*4", 14},
        {"(2+3)*4", 20},
        {"10-2-3", 5},
        {"10/2/5", 1},
        {"2.5+1.5", 4.0},
        {"42", 42}
      ] do
    test "#{input} == #{expected}, agreeing with Grammar.LR and Grammar.VM", %{grammar: grammar} do
      assert Native.LrCalculator.run(unquote(input)) == {:ok, unquote(expected)}

      assert Grammar.LR.run(grammar, unquote(input), LrCalculator.Actions) ==
               {:ok, unquote(expected)}
    end
  end

  test "a malformed expression is a clean parse error, not a crash" do
    assert {:error, _} = Native.LrCalculator.run("1+")
    assert {:error, _} = Native.LrCalculator.run("1+*2")
  end

  test "parse/1 is a bare recognizer, returning the consumed position and raw captures" do
    assert {:ok, 1, _raw_captures} = Native.LrCalculator.parse("42")
  end
end
