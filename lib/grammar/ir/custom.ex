defmodule Grammar.IR.Custom do
  @moduledoc """
  `@native("Module", "function", dep1, dep2, ...)`: a rule body that
  delegates to hand-written Elixir code (an `Ichor.CustomRule`
  implementation) instead of ordinary `Grammar.IR` combinators -- the
  escape hatch for constructs no static PEG grammar can express (a
  Prolog-style mutable operator-precedence table, C's typedef-vs-
  expression ambiguity, and similar "what matches here depends on
  something read earlier" problems).

  `deps` names the only other rules `module`/`function` is allowed to
  call back into (via the `rule_matchers` map `Ichor.CustomRule.match/4`
  receives) -- keeping this node's dependencies visible to
  `Grammar.Analysis`'s reference check even though its own body is
  opaque. `nullable`/`leading` are author-supplied facts standing in for
  what `Grammar.Analysis` would otherwise compute structurally (it can't,
  since the body is arbitrary code): `nullable` defaults to `false`
  (matches the common case -- most custom recognizers consume
  something), `leading` defaults to `deps` (conservative -- assumes it
  might call any declared dependency as its very first, unconsumed
  action, for left-recursion-cycle detection).
  """

  @type t :: %__MODULE__{
          module: module(),
          function: atom(),
          deps: [atom()],
          nullable: boolean(),
          leading: [atom()],
          meta: Grammar.IR.Meta.t()
        }

  defstruct [:module, :function, deps: [], nullable: false, leading: [], meta: %Grammar.IR.Meta{}]
end
