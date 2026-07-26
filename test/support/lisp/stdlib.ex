defmodule Lisp.Stdlib do
  @moduledoc """
  Layer 2 of the three-layer bootstrap: `stdlib.lisp`, parsed and
  evaluated top-to-bottom starting from Layer 1's context, each
  top-level `defmacro` extending the running context as it goes -- the
  same "sequential accumulation" pattern already used for `def`.
  """

  @external_resource Path.join(__DIR__, "stdlib.lisp")
  @source File.read!(Path.join(__DIR__, "stdlib.lisp"))

  @doc "Loads `stdlib.lisp` into `ctx` (normally Layer 1's primitive-seeded context), returning the extended context."
  @spec load(Aether.Grammar.t(), Lisp.Actions.context()) :: Lisp.Actions.context()
  def load(grammar, ctx) do
    case Grammar.VM.run_sequence(grammar, @source, Lisp.Actions, ctx) do
      {:ok, _values, final_ctx} -> final_ctx
      {:error, error} -> raise "failed to load stdlib.lisp: #{inspect(error)}"
    end
  end

  @doc "`stdlib.lisp`'s raw source -- for a caller (e.g. the native backend's own bootstrap) that runs `run_sequence` itself rather than through `load/2`'s `Grammar.VM`-specific call."
  @spec source() :: String.t()
  def source, do: @source
end
