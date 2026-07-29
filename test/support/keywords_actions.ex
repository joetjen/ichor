defmodule KeywordsTest.Actions do
  @moduledoc """
  Evaluates the token stream `@keywords`/`@refine` reclassified: each
  `item` becomes a plain tagged value so a test can assert on the exact
  sequence a source string produced, proving both the `@keywords` table
  lookup and the `@refine` lookbehind actually changed what the parser
  saw (not just that parsing didn't crash).

  `:DIV`/`:REGEX_START` never reach `handle_token` at all --
  `KeywordsTest.SlashDisambiguator.refine/4` hands back its own value
  directly, which becomes the token's capture override (see
  `Ichor.TokenRefiner`), the same mechanism a `@refine`-decoded escape
  sequence would use.
  """

  @behaviour Ichor.Actions

  @impl true
  def handle_token(:KEYWORD_IF, _text, _ctx), do: {:ok, :if}
  def handle_token(:KEYWORD_RETURN, _text, _ctx), do: {:ok, :return}
  def handle_token(:WORD, text, _ctx), do: {:ok, {:ident, text}}
  def handle_token(:NUMBER, text, _ctx), do: {:ok, {:num, String.to_integer(text)}}

  @impl true
  def handle_rule(:program, %{item: items}, ctx) do
    with {:ok, resolved, ctx} <- Ichor.Actions.eval_all(%{item: items}, ctx) do
      {:ok, resolved.item, ctx}
    end
  end
end
