defmodule Native.LrCalculator do
  @moduledoc "Native-backend wiring for the @engine lr calculator fixture -- compiled via Grammar.Native.LR."

  use Ichor,
    grammar: "../lr_calculator/lr_calculator.aether",
    actions: LrCalculator.Actions
end
