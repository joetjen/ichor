defmodule Grammar.IR.RuleRef do
  @moduledoc "Reference to another rule (or token), by name."

  @type t :: %__MODULE__{name: atom(), meta: Grammar.IR.Meta.t()}

  defstruct name: nil, meta: %Grammar.IR.Meta{}
end
