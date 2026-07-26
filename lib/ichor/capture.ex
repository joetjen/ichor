defmodule Ichor.Capture do
  @moduledoc """
  Every capture an action receives bundles the raw parsed structure with
  a callable to evaluate it: `node` is always available, unevaluated --
  what `quote` returns directly. `eval` is what an action calls when it
  actually wants a child's value, with an explicit context it controls.
  Never evaluated automatically -- that's the whole point: a special
  form like `if` or `quote` decides *whether* and *when* to call `eval`
  at all, which is exactly what lets an untaken `if` branch, or `quote`'s
  own argument, go unevaluated (and unbound-symbol/nonterminating errors
  inside them stay latent) instead of always eagerly running.
  """

  @type node_t :: {:token, atom(), String.t()} | {:rule, atom(), map()} | {:text, String.t()}

  @type eval_fun :: (term() -> {:ok, term(), term()} | {:error, Ichor.Error.t()})

  @type t :: %__MODULE__{node: node_t(), eval: eval_fun()}

  defstruct [:node, :eval]
end
