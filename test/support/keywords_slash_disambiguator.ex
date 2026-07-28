defmodule KeywordsTest.SlashDisambiguator do
  @moduledoc """
  The `@refine(...)` half of the fixture: `@keywords` alone (a plain
  table lookup keyed on a token's own text) can't express this one --
  disambiguating a bare `/` requires looking at what came immediately
  before it, the classic JS regex-literal-vs-division-operator case.
  A `/` right after a value (a number or an identifier) is division;
  anywhere else (start of input, after `return`, ...) it starts an
  expression, i.e. what would be a regex literal in JS.
  """

  @behaviour Ichor.TokenRefiner

  @impl true
  def refine(:SLASH, _text, _pos, preceding) do
    case last_significant(preceding) do
      %{name: name} when name in [:NUMBER, :WORD] -> {:ok, :DIV, :div}
      _ -> {:ok, :REGEX_START, :regex_start}
    end
  end

  defp last_significant(tokens) do
    Enum.find(Enum.reverse(tokens), &(&1.name != :WS))
  end
end
