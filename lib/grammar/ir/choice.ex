defmodule Grammar.IR.Choice do
  @moduledoc "Ordered PEG choice: `a | b | c` -- first match wins, always."

  @type t :: %__MODULE__{exprs: [Grammar.IR.expr()], meta: Grammar.IR.Meta.t()}

  defstruct exprs: [], meta: %Grammar.IR.Meta{}
end
