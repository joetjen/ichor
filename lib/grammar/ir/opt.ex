defmodule Grammar.IR.Opt do
  @moduledoc "Zero or one: `expr?`."

  @type t :: %__MODULE__{expr: Grammar.IR.expr(), meta: Grammar.IR.Meta.t()}

  defstruct expr: nil, meta: %Grammar.IR.Meta{}
end
