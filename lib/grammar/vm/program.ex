defmodule Grammar.VM.Program do
  @moduledoc """
  Linked PEG bytecode: every token (or every rule) in a grammar, compiled
  into one shared instruction tuple so `:call` can jump between them by
  index, plus a name -> entry-index map for looking up where to start.

  `Grammar.VM` compiles two of these per grammar -- one over tokens
  (character-level, run by the lexer) and one over rules (token-stream
  level, run by the parser), since Aether grammars are a genuine two-stage
  Lexer -> Parser, not a single scannerless recognizer.
  """

  @type t :: %__MODULE__{instructions: tuple(), entry_points: %{atom() => non_neg_integer()}}

  defstruct [:instructions, :entry_points]
end
