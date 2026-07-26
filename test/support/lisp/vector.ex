defmodule Lisp.Vector do
  @moduledoc "A reified Lisp vector `[a b c]` -- its own tagged wrapper so it stays distinguishable from `list`."

  @type t :: %__MODULE__{items: [term()]}

  defstruct items: []
end
