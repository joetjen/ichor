defmodule DanglingElseTest.Actions do
  @moduledoc "Builds `{:if, cond, then_branch, else_branch_or_nil}`, so a test can see exactly which `if` an `else` attached to."

  @behaviour Ichor.Actions

  @impl true
  def handle_token(:COND, text, _ctx), do: {:ok, String.to_atom(text)}
  def handle_token(:OTHER, text, _ctx), do: {:ok, String.to_integer(text)}

  @impl true
  def handle_rule(:if_stmt, captures, ctx) do
    with {:ok, cond_val, ctx} <- captures.cond.eval.(ctx),
         {:ok, then_branch, ctx} <- captures.then_branch.eval.(ctx),
         {:ok, else_branch, ctx} <- eval_else(captures, ctx) do
      {:ok, {:if, cond_val, then_branch, else_branch}, ctx}
    end
  end

  defp eval_else(%{else_branch: cap}, ctx), do: cap.eval.(ctx)
  defp eval_else(_captures, ctx), do: {:ok, nil, ctx}
end
