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
end
