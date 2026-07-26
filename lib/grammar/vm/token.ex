defmodule Grammar.VM.Token do
  @moduledoc """
  One lexed token from `Grammar.VM.Lexer` -- the target grammar's own
  tokens (e.g. a calculator's `NUMBER`, `"+"`), not to be confused with
  `Aether.Token` (Ichor's front-end lexing `.aether` source itself).
  """

  @type t :: %__MODULE__{
          name: atom(),
          text: String.t(),
          line: pos_integer(),
          column: pos_integer()
        }

  defstruct [:name, :text, :line, :column]
end
