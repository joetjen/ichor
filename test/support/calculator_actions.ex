defmodule Calculator.Actions do
  @moduledoc """
  A worked example, verbatim: proof that `Ichor.Actions` actually
  drives the calculator grammar end to end, through `Grammar.VM`.
  """

  @behaviour Ichor.Actions

  @impl true
  def handle_token(:NUMBER, text, _ctx) do
    {:ok,
     if(String.contains?(text, "."), do: String.to_float(text), else: String.to_integer(text))}
  end

  @impl true
  def handle_rule(:expr, %{op: ops, term: terms}, ctx), do: fold_binop(terms, ops, ctx)
  def handle_rule(:term, %{op: ops, factor: factors}, ctx), do: fold_binop(factors, ops, ctx)

  defp fold_binop([first | rest], ops, ctx) do
    {:ok, first_val, ctx} = first.eval.(ctx)

    Enum.zip(ops, rest)
    |> Enum.reduce({:ok, first_val, ctx}, fn
      {op, term}, {:ok, acc, ctx} ->
        {:ok, op_val, ctx} = op.eval.(ctx)
        {:ok, term_val, ctx} = term.eval.(ctx)
        {:ok, apply_op(op_val, acc, term_val), ctx}
    end)
  end

  defp apply_op("+", a, b), do: a + b
  defp apply_op("-", a, b), do: a - b
  defp apply_op("*", a, b), do: a * b
  defp apply_op("/", a, b), do: a / b
end
