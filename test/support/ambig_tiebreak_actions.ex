defmodule AmbigTiebreakTest.Actions do
  @moduledoc "Reports which of s's two equally-valid derivations actually won."

  @behaviour Ichor.Actions

  @impl true
  def handle_token(:X, _text, _ctx), do: {:ok, :x}

  @impl true
  def handle_rule(:s, %{a: _}, ctx), do: {:ok, :picked_a, ctx}
  def handle_rule(:s, %{b: _}, ctx), do: {:ok, :picked_b, ctx}
end
