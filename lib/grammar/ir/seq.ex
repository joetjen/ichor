defmodule Grammar.IR.Seq do
  @moduledoc "Ordered sequence of sub-expressions: `a b c`."

  @type t :: %__MODULE__{exprs: [Grammar.IR.expr()], meta: Grammar.IR.Meta.t()}

  defstruct exprs: [], meta: %Grammar.IR.Meta{}
end
