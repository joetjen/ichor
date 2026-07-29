defmodule Shell.Heredoc do
  @moduledoc """
  Toy stand-in for a shell-style heredoc (`<<EOF\\n...\\nEOF`): the
  terminator is read off the source itself, not known by the grammar
  ahead of time -- exactly the "lexing depends on something read earlier
  in the same token" problem a fixed maximal-munch tokenizer can't
  express on its own.

  Returns the *body* (between the marker line and the terminator line)
  as an explicit `{:text, body}` capture override, so the grammar sees
  just the heredoc's content -- not the `<<EOF`/terminator delimiters --
  without needing its own `handle_token` clause at all.
  """

  def scan(input, _context, _rule_matchers) do
    with {:ok, term, after_marker} <- match_marker(input),
         {:ok, body, rest} <- consume_until_terminator(after_marker, term) do
      text = binary_part(input, 0, byte_size(input) - byte_size(rest))
      {:ok, text, rest, {:text, body}}
    else
      :fail -> :fail
    end
  end

  defp match_marker(<<"<<", rest::binary>>) do
    case take_ident(rest, []) do
      {"", _rest} -> :fail
      {term, <<"\n", after_newline::binary>>} -> {:ok, term, after_newline}
      _ -> :fail
    end
  end

  defp match_marker(_), do: :fail

  defp take_ident(<<c, rest::binary>>, acc) when c in ?A..?Z or c in ?a..?z do
    take_ident(rest, [c | acc])
  end

  defp take_ident(rest, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}

  defp consume_until_terminator(input, term), do: scan_lines(input, term, [])

  defp scan_lines(input, term, acc) do
    case String.split(input, "\n", parts: 2) do
      [^term, rest] -> {:ok, acc |> Enum.reverse() |> Enum.join("\n"), rest}
      [^term] -> {:ok, acc |> Enum.reverse() |> Enum.join("\n"), ""}
      [_line] -> :fail
      [line, rest] -> scan_lines(rest, term, [line | acc])
    end
  end
end
