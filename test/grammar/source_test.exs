defmodule Grammar.SourceTest do
  use ExUnit.Case, async: true

  alias Grammar.Source

  test "valid UTF-8 passes through unchanged" do
    assert Source.validate("hello, ééé") == {:ok, "hello, ééé"}
  end

  test "an empty string is valid" do
    assert Source.validate("") == {:ok, ""}
  end

  test "invalid UTF-8 is rejected with a lexer-stage error" do
    invalid = <<"abc"::binary, 0xFF, "def"::binary>>
    assert {:error, %Ichor.Error{stage: :lexer, message: message}} = Source.validate(invalid)
    assert message =~ "not valid UTF-8"
  end

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
