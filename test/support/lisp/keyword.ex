defmodule Lisp.Keyword do
  @moduledoc "A reified Lisp keyword, e.g. `:private`."

  @type t :: %__MODULE__{name: String.t()}

  defstruct [:name]
end
