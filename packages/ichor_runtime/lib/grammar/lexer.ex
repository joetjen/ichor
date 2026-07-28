defmodule Grammar.Lexer do
  @moduledoc """
  The Lexer stage of Aether's Reader/Tokenizer/Lexer/Parser split: walks
  a Tokenizer's raw token stream left-to-right, applying every
  `@keywords`/`@refine` rule an `Aether.Grammar`'s `refiners` map
  declares, before the Parser ever runs.

  Shared by both backends (`Grammar.VM` calls this directly;
  `Grammar.Native`'s generated `tokenize/2` calls it with
  `grammar.refiners` spliced in as a literal at compile time) since this
  operates purely on already-produced tokens plus a small data table --
  unlike the Tokenizer/Parser stages, there's no per-grammar compiled
  matching logic to generate here, `@keywords` is just a plain map and
  `@refine` just dispatches to an already-compiled module by name.
  """

  alias Grammar.VM.Token
  alias Ichor.Error

  @doc """
  Reclassifies `tokens` in order, or reports the first `@refine`-rejected
  one. `refiners` empty is the overwhelmingly common case (most grammars
  have no `@keywords`/`@refine` at all), short-circuited without walking
  the list.
  """
  @spec reclassify([Token.t()], %{atom() => Aether.Grammar.refiner()}) ::
          {:ok, [Token.t()]} | {:error, Error.t()}
  def reclassify(tokens, refiners) when map_size(refiners) == 0, do: {:ok, tokens}

  def reclassify(tokens, refiners), do: do_reclassify(tokens, refiners, [])

  defp do_reclassify([], _refiners, acc), do: {:ok, Enum.reverse(acc)}

  defp do_reclassify([token | rest], refiners, acc) do
    case Map.fetch(refiners, token.name) do
      :error ->
        do_reclassify(rest, refiners, [token | acc])

      {:ok, refiner} ->
        case apply_refiner(refiner, token, acc) do
          {:ok, new_name, capture} ->
            reclassified = %{token | name: new_name, capture: capture}
            do_reclassify(rest, refiners, [reclassified | acc])

          {:error, reason} ->
            {:error,
             Error.new(
               message: reason,
               stage: :lexer,
               line: token.line,
               column: token.column
             )}
        end
    end
  end

  defp apply_refiner({:keywords, table}, token, _preceding_rev) do
    case Map.fetch(table, token.text) do
      {:ok, new_name} -> {:ok, new_name, nil}
      :error -> {:ok, token.name, nil}
    end
  end

  defp apply_refiner({:custom, module, function, _possible}, token, preceding_rev) do
    pos = {token.line, token.column}
    preceding = Enum.reverse(preceding_rev)

    case apply(module, function, [token.name, token.text, pos, preceding]) do
      {:ok, new_name, value} -> {:ok, new_name, {:text, value}}
      {:error, _reason} = err -> err
    end
  end
end
