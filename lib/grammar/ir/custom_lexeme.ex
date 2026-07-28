defmodule Grammar.IR.CustomLexeme do
  @moduledoc """
  `@native("Module", "function", dep1, ...)` at *token* position: a
  token whose entire body is hand-written Elixir code (an
  `Ichor.CustomLexeme` implementation) instead of ordinary character-level
  combinators -- the escape hatch for lexical constructs no fixed
  maximal-munch tokenizer can express (a heredoc's dynamic terminator, a
  string literal with embedded interpolated expressions).

  Unlike `Grammar.IR.Custom` (the rule-position sibling), this always
  stands alone as an entire token definition -- it can't be referenced
  from another token's body (there's no compiled entry point for
  `{:call, name}` to jump into) and can't be composed inside a larger
  token expression. `deps` names the *rules* (never tokens) this
  callback may call back into via the re-lex-and-match primitive
  `Ichor.CustomLexeme.match/3` receives. `nullable` is the same
  author-supplied stand-in `Grammar.IR.Custom` uses, defaulting to
  `false`; there's no `leading` here since left-recursion-cycle
  detection is a rule-level concept only.
  """

  @type t :: %__MODULE__{
          module: module(),
          function: atom(),
          deps: [atom()],
          nullable: boolean(),
          meta: Grammar.IR.Meta.t()
        }

  defstruct [:module, :function, deps: [], nullable: false, meta: %Grammar.IR.Meta{}]
end
