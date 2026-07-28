defmodule Ichor.CustomRule do
  @moduledoc """
  The behaviour a `Grammar.IR.Custom` `@native("Module", "function", ...)`
  node dispatches to -- the escape hatch for grammar constructs no static
  PEG grammar can express: a Prolog-style mutable operator-precedence
  table, C's typedef-vs-expression ambiguity, and similar "what matches
  here depends on something read earlier" problems.

  `match/4` receives:

    - `stream`/`pos` -- the same token stream and position any compiled
      rule matcher already works over; advance `pos` however far was
      consumed, same contract as everywhere else.
    - `context` -- read-only. Whatever `Ichor.Actions.evaluate/5` last
      produced from a *previous* top-level form (via `run_sequence/4`),
      or whatever `run/4`'s `initial_context` was outside a sequence.
      Matching never produces a *new* context; only evaluating a
      previous form does.
    - `rule_matchers` -- a map restricted to exactly the dependencies
      declared in `@native(...)`'s own argument list (never the whole
      compiled grammar), each a `(stream, pos -> {:ok, new_pos,
      Ichor.Capture.node_t()} | :fail)` function delegating back into
      the grammar's own compiled rule of that name.

  The return shape is the same `Ichor.Capture.node_t()` every other rule
  produces, so whatever the callback returns plugs straight into ordinary
  `Ichor.Actions.handle_rule`/`handle_token` dispatch downstream, with no
  special-casing.

  `@native("Module", "function", ...)` names its own callback function
  explicitly, so it doesn't have to be called `match` -- `@behaviour
  Ichor.CustomRule` + `@impl true` is a convenience for a module that
  happens to name its callback `match/4` (the common case), not a
  requirement; a differently-named function of the same shape works
  exactly the same way, it just implements this informally.
  """

  alias Ichor.Capture

  @type rule_matcher :: (tuple(), non_neg_integer() ->
                           {:ok, non_neg_integer(), Capture.node_t()} | :fail)
  @type rule_matchers :: %{optional(atom()) => rule_matcher()}

  @callback match(
              stream :: tuple(),
              pos :: non_neg_integer(),
              context :: term(),
              rule_matchers :: rule_matchers()
            ) :: {:ok, non_neg_integer(), Capture.node_t()} | :fail
end
