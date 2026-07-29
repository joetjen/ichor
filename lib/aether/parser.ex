defmodule Aether.Parser do
  @moduledoc """
  Parses `.aether` source into a fully resolved `Aether.Grammar`, in two
  stages: `Aether.Reader` (pure syntax -- a token/rule reference split,
  pragmas, the expression grammar -- into a concrete syntax tree with no
  desugaring) followed by `Aether.Eval` (that CST into `Grammar.IR`,
  handling everything that needs whole-grammar context: predefined-token
  override/use tracking, case-insensitivity, character-class/regex
  desugaring, inline-literal promotion, `@skip` splicing, and final
  `@root`/`@skip` validation).

  This module is the combined convenience entry point -- same relationship
  `run/1,2` has to `parse/1` on a generated grammar module, or `Grammar.VM`'s
  own `run/4` has to `parse/2`.
  """

  alias Aether.{Eval, Reader}
  alias Ichor.Error

  @doc "Parses `source` into a fully compiled `Aether.Grammar`."
  @spec parse(String.t(), String.t() | nil) :: {:ok, Aether.Grammar.t()} | {:error, Error.t()}
  def parse(source, file \\ nil) do
    with {:ok, reader_grammar} <- Reader.read(source, file) do
      Eval.build(reader_grammar)
    end
  end
end
