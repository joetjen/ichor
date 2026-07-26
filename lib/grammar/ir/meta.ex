defmodule Grammar.IR.Meta do
  @moduledoc """
  Source-location metadata carried by every `Grammar.IR` node, so an error
  raised at any later stage (analysis, either backend) can still point
  back at the exact line/column in the original grammar file rather than
  just naming an IR node in the abstract.
  """

  @typedoc "1-based line, 1-based column, match length in the original source."
  @type source_span ::
          {line :: pos_integer(), column :: pos_integer(), length :: non_neg_integer()}

  @type t :: %__MODULE__{
          source_span: source_span() | nil,
          source_format: atom() | nil
        }

  defstruct [:source_span, :source_format]
end
