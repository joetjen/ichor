defmodule Ichor.CustomLexeme do
  @moduledoc """
  The behaviour a `Grammar.IR.CustomLexeme` `@native("Module",
  "function", ...)` node (at *token* position) dispatches to -- the
  escape hatch for lexical constructs a fixed maximal-munch tokenizer
  can't express: a heredoc's dynamic terminator, a string literal with
  embedded interpolated expressions, a `\\catcode`-style mid-scan
  reconfiguration.

  `scan/3` receives:

    - `input` -- the *remaining suffix* of the source text, not a
      position into some fixed original string (matching the convention
      every other char-level matcher in this codebase already uses:
      "what's left" rather than "where am I").
    - `context` -- read-only, same meaning as `Ichor.CustomRule.match/4`'s
      -- whatever the previous top-level form evaluated to, or `nil`
      outside a sequence.
    - `rule_matchers` -- a map restricted to `@native(...)`'s declared
      dependencies (always *rules*, never tokens -- the one narrow,
      explicit carve-out to "a token body may only reference other
      tokens"), each a `(input -> {:ok, text, rest, capture} | :fail)`
      function: re-lexes `input` from scratch and matches the named
      rule, returning how much was consumed and that rule's own raw
      capture, wrapped as `{:rule, name, captures}`.

  Returns `{:ok, text, rest, capture}` where `text <> rest == input`.
  `capture`, unlike an ordinary token's flat text, may be `nil` (this
  token behaves like any other -- its capture is built as `{:token,
  name, text}` downstream, same as if a plain char-level pattern had
  matched) or an explicit `Ichor.Capture.node_t()` overriding that
  default -- what a string-interpolation token needs, to carry its
  embedded expressions' parsed structure through to `Ichor.Actions`
  rather than collapsing them into flat text.

  Unlike `Ichor.CustomRule`, this always stands alone as an entire token
  definition (see `Grammar.IR.CustomLexeme`'s own moduledoc for why), so
  there's no `rule_matchers`-style callback *into* this token from
  elsewhere to worry about.
  """

  alias Ichor.Capture

  @type rule_matcher ::
          (String.t() -> {:ok, String.t(), String.t(), Capture.node_t()} | :fail)
  @type rule_matchers :: %{optional(atom()) => rule_matcher()}

  @callback scan(input :: String.t(), context :: term(), rule_matchers :: rule_matchers()) ::
              {:ok, text :: String.t(), rest :: String.t(), Capture.node_t() | nil} | :fail
end
