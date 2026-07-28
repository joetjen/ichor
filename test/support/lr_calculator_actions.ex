defmodule LrCalculator.Actions do
  @moduledoc """
  Same language, same results as `Calculator.Actions` -- but
  `test/lr_calculator/lr_calculator.aether` writes `expr`/`term` as
  genuinely left-recursive productions (`expr := expr op:(...) term |
  term`) rather than the PEG-idiomatic `term (op:(...) term)*` the
  original calculator grammar uses, so the capture shape differs (a
  self-recursive `expr`/`term` key on the recursive alternative, instead
  of a flat list of repeated `term`s).

  The base alternative (`expr := term`, a single bare capture) never
  reaches `handle_rule/3` at all -- `Ichor.Actions`' own "exactly one
  capture passes straight through" default already handles it, same as
  every other backend. `factor`'s parenthesized alternative has three
  captures (`LPAREN`/`expr`/`RPAREN`), but only `expr`'s value matters;
  matching just `%{expr: expr}` ignores the rest.
  """

  @behaviour Ichor.Actions

  @impl true
  def handle_token(:NUMBER, text, _ctx) do
    {:ok,
     if(String.contains?(text, "."), do: String.to_float(text), else: String.to_integer(text))}
  end

  @impl true
  def handle_rule(:expr, %{expr: expr, op: op, term: term}, ctx) do
    with {:ok, l, ctx} <- expr.eval.(ctx),
         {:ok, o, ctx} <- op.eval.(ctx),
         {:ok, r, ctx} <- term.eval.(ctx) do
      {:ok, apply_op(o, l, r), ctx}
    end
  end

  def handle_rule(:term, %{term: term, op: op, factor: factor}, ctx) do
    with {:ok, l, ctx} <- term.eval.(ctx),
         {:ok, o, ctx} <- op.eval.(ctx),
         {:ok, r, ctx} <- factor.eval.(ctx) do
      {:ok, apply_op(o, l, r), ctx}
    end
  end

  def handle_rule(:factor, %{expr: expr}, ctx), do: expr.eval.(ctx)

  defp apply_op("+", a, b), do: a + b
  defp apply_op("-", a, b), do: a - b
  defp apply_op("*", a, b), do: a * b
  defp apply_op("/", a, b), do: a / b
end
