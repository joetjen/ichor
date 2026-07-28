defmodule Ichor.Toolkit.Layout do
  @moduledoc """
  The off-side-rule (indentation-sensitive layout) algorithm Python's
  own tokenizer uses, and Haskell's/F#'s: given each logical line's
  indentation width, in order, maintain a stack of open indentation
  levels and emit `:indent`/`:dedent` markers as the width rises or
  falls -- so a parser downstream never has to know about columns at
  all, just consumes ordinary tokens.

  This is deliberately a *different* strategy from Ichor's own
  `Grammar.IR.Indent`/`@samecol` (column-position checks embedded
  directly inside grammar rules as zero-width assertions) -- not a
  replacement for it, and not something Ichor's core needs, since it
  already made that different design choice. It exists for a grammar
  author porting a real language whose own reference implementation
  synthesizes `INDENT`/`DEDENT` pseudo-tokens at the lexer level (as
  Python's, Haskell's, and F#'s all do) and would rather mirror that
  approach directly than rewrite it as embedded column checks.

  Deliberately unopinionated about what counts as a line worth
  indentation-checking at all (blank lines, comment-only lines, and
  lines continued inside brackets are all real, genuinely
  language-specific policy choices) -- a caller decides which lines to
  feed in and what each one's width is; this only implements the
  mechanical stack-based algorithm on top of that decision.
  """

  @type width :: non_neg_integer()
  @type marker :: :indent | :dedent

  @doc """
  Given the next logical line's `width` and the current stack of open
  indentation levels (`[0]` for a fresh start), returns the markers to
  emit before that line's own content, and the updated stack.

  A width greater than the current top pushes a new level and emits one
  `:indent`. An equal width emits nothing. A lesser width pops every
  level greater than `width`, emitting one `:dedent` per pop -- an error
  if popping never lands exactly on `width` (dedenting to a level that
  was never open, e.g. mismatched indentation using tabs vs. spaces).
  """
  @spec step(width(), [width(), ...]) ::
          {:ok, [marker()], [width(), ...]} | {:error, {:inconsistent_dedent, width(), [width()]}}
  def step(width, [top | _] = stack) when width > top, do: {:ok, [:indent], [width | stack]}
  def step(width, [top | _] = stack) when width == top, do: {:ok, [], stack}

  def step(width, stack) do
    {dedents, new_stack} = pop_to(width, stack, [])

    case new_stack do
      [^width | _] -> {:ok, Enum.reverse(dedents), new_stack}
      _ -> {:error, {:inconsistent_dedent, width, stack}}
    end
  end

  defp pop_to(width, [top | rest], acc) when top > width, do: pop_to(width, rest, [:dedent | acc])
  defp pop_to(_width, stack, acc), do: {acc, stack}

  @doc "Every `:dedent` needed to close all remaining open levels at end of input, leaving only the base level."
  @spec close([width(), ...]) :: [marker()]
  def close(stack), do: List.duplicate(:dedent, length(stack) - 1)
end
