defmodule Grammar.LexerTest do
  use ExUnit.Case, async: true

  alias Grammar.Lexer
  alias Grammar.VM.Token

  defp token(name, text), do: %Token{name: name, text: text, line: 1, column: 1}

  test "no refiners: tokens pass through unchanged" do
    tokens = [token(:WORD, "if")]
    assert Lexer.reclassify(tokens, %{}) == {:ok, tokens}
  end

  test "@keywords: a table match reclassifies the token, a miss leaves it alone" do
    refiners = %{WORD: {:keywords, %{"if" => :KEYWORD_IF}}}

    assert {:ok, [%Token{name: :KEYWORD_IF}]} = Lexer.reclassify([token(:WORD, "if")], refiners)
    assert {:ok, [%Token{name: :WORD}]} = Lexer.reclassify([token(:WORD, "x")], refiners)
  end

  test "@refine: dispatches to the named module/function with the preceding tokens" do
    refiners = %{SLASH: {:custom, Grammar.LexerTest.Refiner, :refine, [:REGEX]}}
    tokens = [token(:WORD, "return"), token(:SLASH, "/")]

    assert {:ok, [_, %Token{name: :REGEX, capture: {:text, "/"}}]} =
             Lexer.reclassify(tokens, refiners)
  end

  test "@refine rejecting a token surfaces as a lexer-stage error" do
    refiners = %{SLASH: {:custom, Grammar.LexerTest.RejectingRefiner, :refine, [:REGEX]}}

    assert {:error, %Ichor.Error{stage: :lexer, message: "nope"}} =
             Lexer.reclassify([token(:SLASH, "/")], refiners)
  end

  defmodule Refiner do
    def refine(_name, text, _pos, _preceding), do: {:ok, :REGEX, text}
  end

  defmodule RejectingRefiner do
    def refine(_name, _text, _pos, _preceding), do: {:error, "nope"}
  end
end
