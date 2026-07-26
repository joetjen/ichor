defmodule Grammar.IR.Plus do
  @moduledoc "One or more: `expr+`."

  @type t :: %__MODULE__{expr: Grammar.IR.expr(), meta: Grammar.IR.Meta.t()}

  defstruct expr: nil, meta: %Grammar.IR.Meta{}
end
