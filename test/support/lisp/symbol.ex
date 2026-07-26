defmodule Lisp.Symbol do
  @moduledoc "A reified Lisp symbol, e.g. `foo`, `+`, `defmacro`."

  @type t :: %__MODULE__{name: String.t(), meta: map() | nil}

  defstruct [:name, meta: nil]
end
