defmodule IchorTest do
  use ExUnit.Case, async: true
  doctest Ichor

  describe "generate/3" do
    # `use Ichor` and `Mix.Tasks.Ichor.Gen` both funnel through this one
    # function -- these tests check it dispatches to the right backend
    # for each `@engine` value, by comparing against calling that
    # backend directly on the same (parsed + analyzed) grammar. Each
    # backend's own generated code is already exercised end to end
    # elsewhere (the `Native.*` support modules' `use Ichor`, and
    # `Mix.Tasks.Ichor.GenTest` for the file-writing path).

    test "a peg grammar dispatches to Grammar.Native.generate/2" do
      source = Support.ExampleGrammars.all()["4.1 calculator"]
      assert same_generated?(source, "calc.aether", Calculator.Actions, Grammar.Native)
    end

    test "an lr grammar dispatches to Grammar.Native.LR.generate/2" do
      source = File.read!("test/lr_calculator/lr_calculator.aether")
      assert same_generated?(source, "lr.aether", LrCalculator.Actions, Grammar.Native.LR)
    end

    test "a glr grammar dispatches to Grammar.Native.GLR.generate/2" do
      source = File.read!("test/ambig_tiebreak/ambig_tiebreak.aether")
      assert same_generated?(source, "glr.aether", AmbigTiebreakTest.Actions, Grammar.Native.GLR)
    end

    test "raises CompileError with a formatted message on a grammar that fails to parse" do
      assert_raise CompileError, ~r/expected @grammar/, fn ->
        Ichor.generate("not a valid grammar at all", "bad.aether", Support.NoActions)
      end
    end
  end

  defp same_generated?(source, file, actions_module, backend) do
    {:ok, grammar} = Aether.Parser.parse(source, file)
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    expected = Macro.to_string(backend.generate(grammar, actions_module))

    Macro.to_string(Ichor.generate(source, file, actions_module)) == expected
  end
end
