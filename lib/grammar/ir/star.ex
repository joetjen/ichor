defmodule Grammar.IR.Star do
  @moduledoc "Zero or more: `expr*`."

  @type t :: %__MODULE__{expr: Grammar.IR.expr(), meta: Grammar.IR.Meta.t()}

  defstruct expr: nil, meta: %Grammar.IR.Meta{}
end
