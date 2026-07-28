defmodule Grammar.SourceTest do
  use ExUnit.Case, async: true

  # Grammar.Source's own unit tests (Grammar.SourceTest) now live in
  # ichor_runtime, alongside the module itself -- this is the one
  # Grammar.Source-adjacent behavior that genuinely needs the full
  # pipeline (both backends, a real compiled grammar), so it stays here.
  test "both backends reject invalid UTF-8 input before crashing a matcher" do
    invalid = <<"1", 0xFF>>
    assert {:error, %Ichor.Error{stage: :lexer}} = Native.Calculator.run(invalid)

    source = Support.ExampleGrammars.all()["4.1 calculator"]
    {:ok, grammar} = Aether.Parser.parse(source)
    {:ok, grammar} = Grammar.Analysis.run(grammar)

    assert {:error, %Ichor.Error{stage: :lexer}} =
             Grammar.VM.run(grammar, invalid, Calculator.Actions)
  end
end
