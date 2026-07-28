defmodule Grammar.Source do
  @moduledoc """
  The very first, Reader-adjacent stage in front of the Tokenizer:
  confirms `input` is valid UTF-8 before any char-level matcher --
  built on Elixir binary pattern matching against `::utf8` codepoints --
  ever touches it. Malformed input left unchecked doesn't fail cleanly:
  it crashes a compiled matcher with a `MatchError` partway through
  tokenizing, deep inside either backend, instead of surfacing as an
  ordinary `Ichor.Error`.

  Shared by both backends (`Grammar.VM.parse/3`/`run_sequence/4` call
  this directly; `Grammar.Native`'s generated `tokenize/2` calls it too)
  since, like `Grammar.Lexer`, this is pure data validation with nothing
  grammar-specific to compile.
  """

  alias Ichor.Error

  @doc "Returns `input` unchanged if it's valid UTF-8, or an `Ichor.Error` (`stage: :lexer`) otherwise."
  @spec validate(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate(input) when is_binary(input) do
    if String.valid?(input) do
      {:ok, input}
    else
      {:error, Error.new(message: "input is not valid UTF-8", stage: :lexer)}
    end
  end
end
