defmodule PegGapTest.Actions do
  @moduledoc """
  Evaluates `rule`/`top` down to how many `A` tokens `rule` itself
  consumed -- the exact number that decides whether PEG's greedy commit
  to `rule`'s first alternative (`A A`) leaves anything for `top`'s own
  trailing `A` reference.

  `rule`'s two alternatives capture `A` under a different shape each --
  `A A` (two ordinary sequence positions, not a `Star`/`Plus`) naturally
  promotes to a 2-element list via plain `merge_capture` list-promotion,
  while the single-`A` alternative leaves it a bare value, since nothing
  here is wrapped in a repetition for `Grammar.VM.RuleCompiler.capture_shapes/1`
  to mark repeatable -- `List.wrap/1` normalizes either shape.
  """

  @behaviour Ichor.Actions

  @impl true
  def handle_token(:A, _text, _ctx), do: {:ok, :a}

  @impl true
  def handle_rule(:rule, %{A: as}, ctx), do: {:ok, length(List.wrap(as)), ctx}

  def handle_rule(:top, %{rule: rule, A: _trailing}, ctx) do
    with {:ok, rule_count, ctx} <- rule.eval.(ctx) do
      {:ok, rule_count, ctx}
    end
  end
end
