defmodule Grammar.IR.Capture do
  @moduledoc "Named capture for AST construction: `name:expr`."

  @type t :: %__MODULE__{name: atom(), expr: Grammar.IR.expr(), meta: Grammar.IR.Meta.t()}

  defstruct [:name, :expr, meta: %Grammar.IR.Meta{}]
end
