defmodule Grammar.IR.Any do
  @moduledoc "Matches any single character: `.`."

  @type t :: %__MODULE__{meta: Grammar.IR.Meta.t()}

  defstruct meta: %Grammar.IR.Meta{}
end
