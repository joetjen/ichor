defmodule Grammar.IR.Indent do
  @moduledoc """
  Indentation-sensitive block: `@indent(expr)` / `@samecol(expr)`.

  Both pragmas produce this node; `kind` distinguishes them since their
  runtime checks differ -- `@indent` requires a column strictly greater
  than the current reference column and resets the reference column to
  the first matched token's column, `@samecol` requires exactly the
  current reference column.
  """

  @type t :: %__MODULE__{
          expr: Grammar.IR.expr(),
          kind: :indent | :samecol,
          meta: Grammar.IR.Meta.t()
        }

  defstruct [:expr, :kind, meta: %Grammar.IR.Meta{}]
end
