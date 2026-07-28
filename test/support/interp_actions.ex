defmodule InterpTest.Actions do
  @moduledoc """
  Evaluates what `JS.StringInterp` built: `:string`'s `segments` list
  interleaves literal-text captures and embedded-`:expr` captures, each
  evaluated in order and concatenated -- the embedded expression really
  is dispatched through the grammar's own `:expr`/`NUMBER` handling, not
  just treated as opaque text.
  """

  @behaviour Ichor.Actions

  @impl true
  def handle_token(:NUMBER, text, _ctx), do: {:ok, String.to_integer(text)}

  @impl true
  def handle_rule(:expr, %{NUMBER: first, n: rest}, ctx) do
    with {:ok, first_val, ctx} <- first.eval.(ctx),
         {:ok, rest_vals, ctx} <- eval_each(rest, ctx) do
      {:ok, Enum.sum([first_val | rest_vals]), ctx}
    end
  end

  def handle_rule(:string, %{segments: segments}, ctx) do
    with {:ok, parts, ctx} <- eval_each(segments, ctx) do
      {:ok, Enum.join(Enum.map(parts, &to_string/1)), ctx}
    end
  end

  defp eval_each(caps, ctx) do
    caps
    |> Enum.reduce_while({:ok, [], ctx}, fn cap, {:ok, acc, ctx} ->
      case cap.eval.(ctx) do
        {:ok, val, ctx} -> {:cont, {:ok, [val | acc], ctx}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc, ctx} -> {:ok, Enum.reverse(acc), ctx}
      {:error, _} = err -> err
    end
  end
end
