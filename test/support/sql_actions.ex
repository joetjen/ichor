defmodule SQL.Actions do
  @moduledoc """
  A "Query (SQL, LogQL)"-style `Ichor.Actions` module: moderate
  complexity, eager evaluation in order, and the root
  rule executes the assembled query against a context-provided data
  source rather than just describing it. Context here is `%{tables: %{
  table_name => [row_map, ...]}}`; `select_stmt`'s own action filters and
  projects those rows, returning the query's actual result set.
  """

  @behaviour Ichor.Actions

  @type context :: %{tables: %{String.t() => [%{String.t() => term()}]}}

  # ---- literals: comparison operators become atoms, not raw operator
  # text, so `condition`'s own action can dispatch on them directly ----

  @impl true
  def handle_token(:EQ, _text, _ctx), do: {:ok, :eq}
  def handle_token(:NEQ, _text, _ctx), do: {:ok, :neq}
  def handle_token(:LE, _text, _ctx), do: {:ok, :le}
  def handle_token(:GE, _text, _ctx), do: {:ok, :ge}
  def handle_token(:LT, _text, _ctx), do: {:ok, :lt}
  def handle_token(:GT, _text, _ctx), do: {:ok, :gt}

  def handle_token(:STRING, text, _ctx), do: {:ok, String.slice(text, 1..-2//1)}
  def handle_token(:NUMBER, text, _ctx), do: {:ok, String.to_integer(text)}

  # `column`/`table_ref` (bare `STAR | IDENT`, `IDENT`) need no token
  # overrides at all: the default fallback's own `{:ok, text}` is already
  # the right value, a plain column/table name (or `"*"`).

  @impl true
  def handle_rule(:column_list, %{column: columns}, ctx) do
    with {:ok, %{column: columns}, ctx} <- Ichor.Actions.eval_all(%{column: columns}, ctx) do
      {:ok, columns, ctx}
    end
  end

  def handle_rule(
        :condition,
        %{IDENT: field_cap, comparison_op: op_cap, literal: literal_cap},
        ctx
      ) do
    with {:ok, field, ctx} <- field_cap.eval.(ctx),
         {:ok, op, ctx} <- op_cap.eval.(ctx),
         {:ok, value, ctx} <- literal_cap.eval.(ctx) do
      {:ok, {field, op, value}, ctx}
    end
  end

  def handle_rule(:where_clause, %{condition: condition_cap}, ctx), do: condition_cap.eval.(ctx)

  def handle_rule(:select_stmt, captures, ctx) do
    with {:ok, columns, ctx} <- captures.column_list.eval.(ctx),
         {:ok, table, ctx} <- captures.table_ref.eval.(ctx),
         {:ok, condition, ctx} <- eval_where(captures, ctx) do
      rows =
        ctx.tables
        |> Map.fetch!(table)
        |> Enum.filter(&matches?(&1, condition))
        |> Enum.map(&project(&1, columns))

      {:ok, rows, ctx}
    end
  end

  defp eval_where(%{where_clause: cap}, ctx), do: cap.eval.(ctx)
  defp eval_where(_captures, ctx), do: {:ok, nil, ctx}

  defp matches?(_row, nil), do: true

  defp matches?(row, {field, op, value}) do
    compare(Map.fetch!(row, field), op, value)
  end

  defp compare(a, :eq, b), do: a == b
  defp compare(a, :neq, b), do: a != b
  defp compare(a, :le, b), do: a <= b
  defp compare(a, :ge, b), do: a >= b
  defp compare(a, :lt, b), do: a < b
  defp compare(a, :gt, b), do: a > b

  defp project(row, ["*"]), do: row
  defp project(row, columns), do: Map.take(row, columns)
end
