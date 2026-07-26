defmodule Ichor.Error do
  @moduledoc """
  One error struct, reused across every stage -- Lexer, Parser, analysis
  pass, and `Ichor.Actions` -- so errors look the same regardless of
  origin.

  `context_lines` is pre-rendered at construction time, not lazily
  computed on access: cheap to do once, and keeps every stage's error
  output visually consistent.
  """

  @type stage :: :lexer | :parser | :analysis | :action

  @type t :: %__MODULE__{
          message: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          file: String.t() | nil,
          context_lines: String.t() | nil,
          expected: term(),
          found: term(),
          stage: stage() | nil
        }

  defstruct [:message, :line, :column, :file, :context_lines, :expected, :found, :stage]

  @doc """
  Builds a `Ichor.Error`, pre-rendering `context_lines` immediately.

  Accepts `:message` (required), `:stage`, `:line`, `:column`, `:file`,
  `:expected`, `:found`, and either `:source` (the full source text, used
  to render a caret-annotated snippet at `:line`/`:column`) or a
  pre-rendered `:context_lines` directly, for callers that already have
  one (e.g. re-wrapping an error from another stage).

  ## Examples

      iex> error = Ichor.Error.new(
      ...>   message: "expected ')'",
      ...>   stage: :parser,
      ...>   line: 1,
      ...>   column: 8,
      ...>   expected: ")",
      ...>   found: :eof,
      ...>   source: "(2 + 3"
      ...> )
      iex> error.context_lines
      "1 | (2 + 3\\n  |        ^"

      iex> Ichor.Error.new(message: "boom", source: nil, line: nil).context_lines
      nil

  """
  @spec new(keyword()) :: t()
  def new(opts) do
    line = Keyword.get(opts, :line)
    column = Keyword.get(opts, :column)
    source = Keyword.get(opts, :source)

    context_lines =
      case Keyword.fetch(opts, :context_lines) do
        {:ok, context_lines} -> context_lines
        :error -> render_context(source, line, column)
      end

    %__MODULE__{
      message: Keyword.fetch!(opts, :message),
      line: line,
      column: column,
      file: Keyword.get(opts, :file),
      context_lines: context_lines,
      expected: Keyword.get(opts, :expected),
      found: Keyword.get(opts, :found),
      stage: Keyword.get(opts, :stage)
    }
  end

  @doc """
  Renders the full human-readable error: location, message, and the
  caret-annotated snippet, in that order.

  ## Examples

      iex> error = Ichor.Error.new(
      ...>   message: "expected ')'",
      ...>   stage: :parser,
      ...>   file: "calc.aether",
      ...>   line: 1,
      ...>   column: 8,
      ...>   source: "(2 + 3"
      ...> )
      iex> Ichor.Error.format(error)
      "calc.aether:1:8: expected ')'\\n1 | (2 + 3\\n  |        ^"

  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = error) do
    [location(error), error.message]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(": ")
    |> append_context(error.context_lines)
  end

  defp location(%__MODULE__{file: file, line: line, column: column}) do
    [file, line, column]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp append_context(header, nil), do: header
  defp append_context(header, context_lines), do: header <> "\n" <> context_lines

  defp render_context(nil, _line, _column), do: nil
  defp render_context(_source, nil, _column), do: nil

  defp render_context(source, line, column) do
    case Enum.at(String.split(source, "\n"), line - 1) do
      nil ->
        nil

      text ->
        gutter = Integer.to_string(line)
        gutter_padding = String.duplicate(" ", String.length(gutter))
        caret_offset = String.duplicate(" ", max(column - 1, 0))

        "#{gutter} | #{text}\n#{gutter_padding} | #{caret_offset}^"
    end
  end
end
