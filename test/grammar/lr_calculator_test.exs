defmodule Grammar.LRCalculatorTest do
  use ExUnit.Case, async: true

  defp lr_grammar do
    source = File.read!(Path.join(__DIR__, "../lr_calculator/lr_calculator.aether"))
    {:ok, grammar} = Aether.Parser.parse(source)
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  defp peg_grammar do
    source = Support.ExampleGrammars.all()["4.1 calculator"]
    {:ok, grammar} = Aether.Parser.parse(source)
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, lr: lr_grammar(), peg: peg_grammar()}
  end

  test "the table is conflict-free", %{lr: lr} do
    assert {:ok, _compiled} = Grammar.LR.compile(lr)
  end

  # `lr_calculator.aether` (left-recursive, no whitespace) and the
  # original "4.1 calculator" (PEG-idiomatic `term (op term)*`, real
  # whitespace support) are two structurally different grammars for the
  # same language -- proving `Grammar.LR` agrees with the trusted PEG
  # backend on every input is the actual point, not that they're the
  # same grammar text.
  for {lr_input, peg_input, expected} <- [
        {"2+3*4", "2 + 3 * 4", 14},
        {"(2+3)*4", "(2 + 3) * 4", 20},
        {"10-2-3", "10 - 2 - 3", 5},
        {"10/2/5", "10 / 2 / 5", 1},
        {"2.5+1.5", "2.5 + 1.5", 4.0},
        {"42", "42", 42}
      ] do
    test "#{lr_input} == #{expected}, agreeing with the PEG backend on #{inspect(peg_input)}", %{
      lr: lr,
      peg: peg
    } do
      assert Grammar.LR.run(lr, unquote(lr_input), LrCalculator.Actions) ==
               {:ok, unquote(expected)}

      assert Grammar.VM.run(peg, unquote(peg_input), Calculator.Actions) ==
               {:ok, unquote(expected)}
    end
  end

  test "a malformed expression is a clean parse error, not a crash", %{lr: lr} do
    assert {:error, _} = Grammar.LR.run(lr, "1+", LrCalculator.Actions)
    assert {:error, _} = Grammar.LR.run(lr, "1+*2", LrCalculator.Actions)
  end
end
