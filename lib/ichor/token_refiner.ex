defmodule Ichor.TokenRefiner do
  @moduledoc """
  The behaviour a `@refine("Module", "function", ...)` token suffix
  dispatches to -- reclassifying (or validating/decoding) a token the
  Tokenizer already matched, before the Parser ever sees it. `@keywords`
  is sugar for the common table-lookup case of this same mechanism (see
  `Grammar.Lexer`); `@refine` is the escape hatch for anything needing
  real logic: escape-sequence decoding, or disambiguating a token based
  on what came immediately before it (JS's `/` being a regex-literal
  start or a division operator, depending on the preceding token).

  `refine/4` receives:

    - `raw_name`/`raw_text` -- the token exactly as the Tokenizer matched
      it.
    - `pos` -- `{line, column}`.
    - `preceding` -- every token already reclassified so far (final
      form, not raw) -- what makes the JS `/` case work: by the time a
      `/` is being refined, whatever came immediately before it already
      reflects its own final classification, not a pre-lexer guess.

  Returns `{:ok, new_name, value}` -- `value` becomes this token's
  capture override (see `Grammar.VM.Token`), same mechanism
  `Ichor.CustomLexeme` uses, so a decoded escape sequence (say) reaches
  `Ichor.Actions` as the token's actual value instead of its raw source
  text -- or `{:error, reason}`, surfaced as an `Ichor.Error` with
  `stage: :lexer`.

  Like `Ichor.CustomRule`/`Ichor.CustomLexeme`, `@refine(...)` names its
  own callback function explicitly, so it doesn't have to be called
  `refine` -- `@behaviour Ichor.TokenRefiner` + `@impl true` is a
  convenience for a module that happens to name it that (the common
  case), not a requirement.
  """

  alias Grammar.VM.Token

  @callback refine(
              raw_name :: atom(),
              raw_text :: String.t(),
              pos :: {pos_integer(), pos_integer()},
              preceding :: [Token.t()]
            ) :: {:ok, new_name :: atom(), value :: term()} | {:error, reason :: String.t()}
end
