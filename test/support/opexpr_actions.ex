defmodule OpExprTest.Actions do
  @moduledoc """
  Evaluates the tree `OpExprTest.Operators` built: `handle_token(:NUMBER,
  ...)` and the `primary := NUMBER` passthrough need nothing special (the
  default single-capture passthrough handles both), so the only rule
  needing real logic is `:expr`'s binary-op shape.
  """

  @behaviour Ichor.Actions

  @impl true
  def handle_token(:NUMBER, text, _ctx), do: {:ok, String.to_integer(text)}

  @impl true
  def handle_rule(:expr, %{op: op, left: left, right: right}, ctx) do
    with {:ok, op_name, ctx} <- op.eval.(ctx),
         {:ok, left_val, ctx} <- left.eval.(ctx),
         {:ok, right_val, ctx} <- right.eval.(ctx) do
      {:ok, apply_op(op_name, left_val, right_val), ctx}
    end
  end

  defp apply_op("plus", a, b), do: a + b
  defp apply_op("times", a, b), do: a * b
  defp apply_op("minus", a, b), do: a - b
end
