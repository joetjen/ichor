defmodule Lisp.Macro do
  @moduledoc """
  A `defmacro` value: `params` is the reified
  param list, `body_node` is the macro's body as a raw, un-evaluated
  `Ichor.Capture.node_t()` -- expansion (`Lisp.Actions.expand_and_eval/3`)
  reifies the macro's *arguments* unevaluated, binds them to `params`,
  evaluates `body_node` in that binding (producing new code), then
  re-evaluates that new code in the *caller's* context. Unhygienic, by
  design -- this is the minimal mechanism needed to show
  `Ichor.Actions` supports macro expansion at all, not a production-grade
  hygienic macro system.
  """

  @type t :: %__MODULE__{params: [Lisp.Symbol.t()], body_node: Ichor.Capture.node_t()}

  defstruct [:params, :body_node]
end
