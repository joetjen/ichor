defmodule Grammar.VM.Lexer do
  @moduledoc """
  Tokenizes a full input string against a `Grammar.VM.CharCompiler`
  program, using maximal munch: at each position, every declared token is
  tried, the longest match wins, ties are broken by declaration order.
  Trivia/skip tokens are emitted like any other -- filtering them out is
  the *parser*'s job, via the `Star(skip_token)` that `Aether.Parser`
  already spliced into rule bodies, not the lexer's.
  """

  alias Grammar.VM.{CharInterpreter, Token}
  alias Ichor.Error

  @doc "Tokenizes `input` completely, or reports the first position nothing matches."
  @spec tokenize(Grammar.VM.Program.t(), [atom()], String.t(), String.t() | nil) ::
          {:ok, [Token.t()]} | {:error, Error.t()}
  def tokenize(program, token_order, input, file \\ nil) do
    do_tokenize(program, token_order, input, input, 1, 1, file, [])
  end

  defp do_tokenize(_program, _token_order, "", _source, _line, _col, _file, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp do_tokenize(program, token_order, input, source, line, col, file, acc) do
    case best_match(program, token_order, input) do
      {:ok, name, text} ->
        token = %Token{name: name, text: text, line: line, column: col}
        {new_line, new_col} = advance(text, line, col)
        rest = binary_part(input, byte_size(text), byte_size(input) - byte_size(text))
        do_tokenize(program, token_order, rest, source, new_line, new_col, file, [token | acc])

      :none ->
        {:error,
         Error.new(
           message: "no token matches here",
           stage: :lexer,
           file: file,
           line: line,
           column: col,
           source: source
         )}
    end
  end

  defp best_match(program, token_order, input) do
    token_order
    |> Enum.reduce(:none, fn name, best ->
      entry = Map.fetch!(program.entry_points, name)

      case CharInterpreter.run(program.instructions, entry, input) do
        {:ok, remaining} -> consider(best, name, byte_size(input) - byte_size(remaining), input)
        :fail -> best
      end
    end)
    |> case do
      :none -> :none
      {name, text} -> {:ok, name, text}
    end
  end

  # Zero-width matches are never accepted as "the next token" -- accepting
  # one would advance nothing and loop forever. Such a token can still
  # exist and be referenced from inside other tokens; it just can't win
  # maximal munch on its own.
  defp consider(best, _name, 0, _input), do: best

  defp consider(:none, name, consumed, input), do: {name, binary_part(input, 0, consumed)}

  defp consider({_, best_text} = best, name, consumed, input) do
    if consumed > byte_size(best_text), do: {name, binary_part(input, 0, consumed)}, else: best
  end

  defp advance(text, line, col) do
    Enum.reduce(String.to_charlist(text), {line, col}, fn
      ?\n, {line, _col} -> {line + 1, 1}
      _, {line, col} -> {line, col + 1}
    end)
  end
end
