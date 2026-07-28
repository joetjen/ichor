defmodule Grammar.VM.Token do
  @moduledoc """
  One lexed token from `Grammar.VM.Tokenizer` -- the target grammar's own
  tokens (e.g. a calculator's `NUMBER`, `"+"`), not to be confused with
  `Aether.Token` (Ichor's front-end lexing `.aether` source itself).

  `capture` is `nil` for an ordinary token (its capture, when some rule
  references it, is built as `{:token, name, text}` from `text` alone).
  A `Grammar.IR.CustomLexeme`-matched token (`Ichor.CustomLexeme.scan/3`
  returning an explicit capture override, not `nil`) carries its own
  structure here instead -- a string-interpolation token's embedded
  expressions, say -- which the rule level uses verbatim in place of the
  usual flat-text capture.
  """

  @type t :: %__MODULE__{
          name: atom(),
          text: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          capture: Ichor.Capture.node_t() | nil
        }

  defstruct [:name, :text, :line, :column, capture: nil]
end
