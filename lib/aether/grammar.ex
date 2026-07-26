defmodule Aether.Grammar do
  @moduledoc """
  The fully compiled output of `Aether.Parser`: grammar-wide settings plus
  every token and rule body, each already resolved to `Grammar.IR`.

  `tokens` holds every token -- user-declared, the five predefined ones
  (`DIGIT`/`ALPHA`/`ALNUM`/`SPACE`/`HEX`, overridden or defaulted), and
  anonymous ones auto-promoted from inline rule literals (a rule body
  writing a bare `"SELECT"` gets an anonymous token generated for it
  automatically, since only tokens participate in lexing) -- keyed by
  name. `rules` holds every rule body, already spliced with `@skip`/`~`.
  Downstream stages (the analysis pass, `Grammar.VM`, native codegen)
  consume this, not raw `.aether` text.

  `token_order` is the declaration order of every name in `tokens` --
  needed by the lexer's maximal-munch rule ("longest match wins, ties
  broken by declaration order"), which a plain map can't answer since
  Elixir maps don't preserve insertion order. Non-overridden predefined
  tokens are appended at the end, in their fixed table order, since they
  were never actually "declared" in the file.

  `anon_tokens` names every token auto-promoted from an inline rule
  literal rather than actually declared. `Grammar.VM`'s rule compiler
  consults this to skip *implicit* self-named captures for them -- a
  grammar author writing a bare `"("` clearly isn't asking to capture it
  under some compiler-generated name; if they wanted it captured, they'd
  give it a real name themselves.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          root: atom(),
          skip: atom() | nil,
          case_insensitive: boolean(),
          tokens: %{atom() => Grammar.IR.expr()},
          token_order: [atom()],
          anon_tokens: MapSet.t(atom()),
          rules: %{atom() => Grammar.IR.expr()},
          source: String.t() | nil,
          file: String.t() | nil
        }

  defstruct [
    :name,
    :root,
    skip: nil,
    case_insensitive: false,
    tokens: %{},
    token_order: [],
    anon_tokens: MapSet.new(),
    rules: %{},
    source: nil,
    file: nil
  ]
end
