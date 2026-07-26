defmodule Lisp.Map do
  @moduledoc "A reified Lisp map `{k v ...}` -- its own tagged wrapper so it stays distinguishable from `list`."

  @type t :: %__MODULE__{pairs: %{optional(term()) => term()}}

  defstruct pairs: %{}
end
