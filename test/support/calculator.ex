defmodule Calculator do
  @moduledoc """
  A worked example for `Ichor.Toolkit.Pratt`, deliberately unrelated to
  grammars or compilers: evaluates arithmetic expressions over infix `+
  - * /`, prefix `-` (negation), postfix `!` (factorial), and `%`
  registered as *both* infix (modulo, `10 % 3`) and postfix (percent,
  `50%` meaning `50 / 100`) -- deliberately the one genuinely ambiguous
  case `Pratt.parse/4` needs a `can_start_operand?` callback to resolve,
  proving that path works, not just the unambiguous ones.
  """

  alias Ichor.Toolkit.Pratt

  @table Pratt.new()
         |> Pratt.prefix("-", 100)
         |> Pratt.infix("+", 10)
         |> Pratt.infix("-", 10)
         |> Pratt.infix("*", 20)
         |> Pratt.infix("/", 20)
         |> Pratt.infix("%", 20)
         |> Pratt.postfix("!", 30)
         |> Pratt.postfix("%", 30)

  @spec eval(String.t()) :: {:ok, number()} | :fail
  def eval(input) do
    tokens = input |> tokenize() |> List.to_tuple()

    callbacks = %{
      peek_op: &peek_op(tokens, &1),
      parse_primary: &parse_number(tokens, &1),
      can_start_operand?: &can_start_operand?(tokens, &1),
      build: &build/3
    }

    with {:ok, pos, value} <- Pratt.parse(@table, 0, callbacks),
         true <- pos == tuple_size(tokens) do
      {:ok, value}
    else
      _ -> :fail
    end
  end

  defp tokenize(input) do
    ~r/[0-9]+|[-+*\/!%]/
    |> Regex.scan(input)
    |> Enum.map(fn [tok] ->
      case Integer.parse(tok) do
        {n, ""} -> {:num, n}
        _ -> {:op, tok}
      end
    end)
  end

  defp peek_op(tokens, pos) do
    case at(tokens, pos) do
      {:op, name} -> {name, pos + 1}
      _ -> nil
    end
  end

  defp parse_number(tokens, pos) do
    case at(tokens, pos) do
      {:num, n} -> {:ok, pos + 1, n}
      _ -> :fail
    end
  end

  # A valid operand starts at `pos` if it's a number or a prefix `-` --
  # exactly what `%`'s infix reading (`a % b`) requires right after the
  # operator; if neither, `%` must have been used postfix instead.
  defp can_start_operand?(tokens, pos) do
    match?({:num, _}, at(tokens, pos)) or match?({:op, "-"}, at(tokens, pos))
  end

  defp at(tokens, pos) when pos >= 0 and pos < tuple_size(tokens), do: elem(tokens, pos)
  defp at(_tokens, _pos), do: nil

  defp build(:prefix, "-", [a]), do: -a
  defp build(:infix, "+", [a, b]), do: a + b
  defp build(:infix, "-", [a, b]), do: a - b
  defp build(:infix, "*", [a, b]), do: a * b
  defp build(:infix, "/", [a, b]), do: a / b
  defp build(:infix, "%", [a, b]), do: rem(a, b)
  defp build(:postfix, "!", [a]), do: factorial(a)
  defp build(:postfix, "%", [a]), do: a / 100

  defp factorial(0), do: 1
  defp factorial(n) when n > 0, do: n * factorial(n - 1)
end
