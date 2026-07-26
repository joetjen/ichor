defmodule Mix.Tasks.Ichor.Tokens do
  @shortdoc "Lists every token a grammar declares, in maximal-munch tie-break order"

  @moduledoc """
  Reads a `.aether` grammar file and lists every token it defines --
  user-declared, anonymous (auto-promoted from an inline rule literal),
  and the five predefined tokens (always present whether overridden or
  left at their default) -- in `token_order`, the same order the Lexer's
  maximal-munch tie-break actually uses, alongside a rendered pattern for
  each (`Grammar.Tokens`).

  Only needs the Aether front-end to run -- no analysis pass, no
  VM/native backend -- so it works on any grammar that parses, even one
  that would later fail the left-recursion/reference-check analysis pass.

      $ mix ichor.tokens sql.aether
      #   NAME    KIND        PATTERN
      1   SELECT  declared    "SELECT"
      2   FROM    declared    "FROM"
      ...
      15  SPACE   declared    [ \\t\\n]+
      16  DIGIT   predefined  [0-9]
      ...
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    case argv do
      [path] -> list_tokens(path)
      _ -> Mix.raise("usage: mix ichor.tokens PATH_TO_GRAMMAR")
    end
  end

  defp list_tokens(path) do
    source = File.read!(path)

    case Aether.Parser.parse(source, path) do
      {:ok, grammar} ->
        grammar
        |> Grammar.Tokens.list()
        |> format_table()
        |> Mix.shell().info()

      {:error, error} ->
        Mix.raise(Ichor.Error.format(error))
    end
  end

  defp format_table(entries) do
    header = ["#", "NAME", "KIND", "PATTERN"]

    rows =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {%{name: name, kind: kind, pattern: pattern}, i} ->
        [Integer.to_string(i), to_string(name), to_string(kind), pattern]
      end)

    widths = column_widths([header | rows])

    [header | rows]
    |> Enum.map_join("\n", &format_row(&1, widths))
  end

  defp column_widths(rows) do
    Enum.zip_with(rows, fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)
  end

  defp format_row(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
    |> String.trim_trailing()
  end
end
