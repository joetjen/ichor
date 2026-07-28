defmodule Ichor.Backtrack.Term do
  @moduledoc """
  The behaviour a caller's own term representation implements so
  `Ichor.Backtrack.Bindings` can unify it -- passed explicitly to every
  `Bindings` function (`resolve/3`, `unify/4`), the same "module passed
  as a plain argument, never looked up dynamically" convention
  `Ichor.Actions.evaluate/5` already uses for an actions module.

  Nothing here prescribes what a term actually *is* -- a caller is free
  to use plain Elixir terms directly for anything atomic (`:tom`, `42`,
  `"a string"`, compared with `==/2`), reserving a distinguishing shape
  only for the two cases that need special handling:

    - `variable?/1` + `var_id/1` -- a logic variable, keyed by whatever
      `var_id/1` returns (this is exactly the key `Bindings` stores a
      binding under, so it must be stable and unique per distinct
      variable -- an Elixir `reference/0` minted fresh per variable is
      a natural choice).
    - `compound?/1` + `deconstruct/1` -- a compound term (`foo(X, bar)`),
      unified by recursively unifying its functor and arguments
      (`deconstruct/1` returning `{functor, args}`); two compound terms
      only unify when their functor and arity both match.

  Anything that's neither a variable nor a compound term is treated as
  atomic and unified with plain `==/2`.

  `reconstruct/2` is optional -- the inverse of `deconstruct/1`, needed
  only by callers that *rebuild* terms rather than just inspect them
  (`Ichor.Toolkit.TypeScheme`'s `generalize/4`/`instantiate/3`, which
  substitute type variables inside a type). Unification itself
  (`Ichor.Backtrack.Bindings`) never needs it -- it only ever compares
  and binds, never constructs.
  """

  @callback variable?(term()) :: boolean()
  @callback var_id(term()) :: term()
  @callback compound?(term()) :: boolean()
  @callback deconstruct(term()) :: {functor :: term(), args :: [term()]}
  @callback reconstruct(functor :: term(), args :: [term()]) :: term()

  @optional_callbacks reconstruct: 2
end
