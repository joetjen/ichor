defmodule Grammar.IR.NotPred do
  @moduledoc "Negative lookahead, consumes nothing: `!expr`."

  @type t :: %__MODULE__{expr: Grammar.IR.expr(), meta: Grammar.IR.Meta.t()}

  defstruct expr: nil, meta: %Grammar.IR.Meta{}
end
