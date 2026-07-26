defmodule Lisp.Closure do
  @moduledoc """
  A `fn` value: `params` is the reified param
  list (a plain Elixir list of `%Lisp.Symbol{}`, the last one optionally
  meaning "rest args" -- see `Lisp.Actions.bind_params/3`), `body_eval` is
  the *unevaluated* body capture (called only when the closure itself is
  applied), and `captured_ctx` is the context at the point `fn` was
  evaluated -- lexical scoping, not the caller's context at application
  time.
  """

  @type t :: %__MODULE__{
          params: [Lisp.Symbol.t()],
          body_eval: Ichor.Capture.eval_fun(),
          captured_ctx: term()
        }

  defstruct [:params, :body_eval, :captured_ctx]
end
