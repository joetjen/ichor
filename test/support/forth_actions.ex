defmodule Forth.Actions do
  @moduledoc """
  A minimal stack-machine interpreter for the `4.8 forth` grammar --
  proof that `Ichor.Actions`'s thunk model (storing a matched rule's
  children as unevaluated `Ichor.Capture`s) works just as
  well for a flat, non-tree-shaped language as it does for LISP's deeply
  nested one: a word definition's body is stored as a list of thunks and
  only evaluated when (and as many times as) the word is later invoked,
  never at definition time.

  Context is `%{stack: [term()], words: %{String.t() => [Ichor.Capture.t()]}}`.
  A handful of native words (`+ - * / dup drop swap`) operate on the
  stack directly; anything else is looked up in `words` (checked after
  the natives, so a user definition can never shadow a native -- not a
  real Forth's actual rule, but a reasonable simplification for a
  fragment whose entire point is proving the thunk model, not being a
  complete Forth).
  """

  @behaviour Ichor.Actions

  @native_words ~w(+ - * / dup drop swap)

  @spec new_context() :: %{stack: [term()], words: %{String.t() => [Ichor.Capture.t()]}}
  def new_context, do: %{stack: [], words: %{}}

  @impl true
  def handle_token(:NUMBER, text, _ctx), do: {:ok, String.to_integer(text)}
  def handle_token(:WORD_NAME, text, _ctx), do: {:ok, text}

  @impl true
  def handle_rule(:form, %{NUMBER: cap}, ctx) do
    with {:ok, value, ctx} <- cap.eval.(ctx) do
      {:ok, value, %{ctx | stack: [value | ctx.stack]}}
    end
  end

  def handle_rule(:form, %{WORD_NAME: cap}, ctx) do
    with {:ok, name, ctx} <- cap.eval.(ctx) do
      invoke(name, ctx)
    end
  end

  def handle_rule(:definition, %{WORD_NAME: name_cap, form: body}, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx) do
      {:ok, name, %{ctx | words: Map.put(ctx.words, name, body)}}
    end
  end

  def handle_rule(:program, %{form: forms}, ctx) do
    with {:ok, %{form: _values}, ctx} <- Ichor.Actions.eval_all(%{form: forms}, ctx) do
      {:ok, ctx.stack, ctx}
    end
  end

  defp invoke(name, ctx) when name in @native_words do
    {:ok, nil, %{ctx | stack: apply_native(name, ctx.stack)}}
  end

  defp invoke(name, ctx) do
    case Map.fetch(ctx.words, name) do
      {:ok, body} ->
        with {:ok, %{body: _values}, ctx} <- Ichor.Actions.eval_all(%{body: body}, ctx) do
          {:ok, nil, ctx}
        end

      :error ->
        {:error, Ichor.Error.new(message: "unbound word: #{name}", stage: :action)}
    end
  end

  defp apply_native("+", [a, b | rest]), do: [b + a | rest]
  defp apply_native("-", [a, b | rest]), do: [b - a | rest]
  defp apply_native("*", [a, b | rest]), do: [b * a | rest]
  defp apply_native("/", [a, b | rest]), do: [div(b, a) | rest]
  defp apply_native("dup", [a | rest]), do: [a, a | rest]
  defp apply_native("drop", [_ | rest]), do: rest
  defp apply_native("swap", [a, b | rest]), do: [b, a | rest]
end
