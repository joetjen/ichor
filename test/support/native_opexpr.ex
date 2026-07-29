defmodule Native.OpExpr do
  @moduledoc "Native-backend wiring for the `@native(...)`/`Grammar.IR.Custom` fixture."

  use Ichor,
    grammar: "../opexpr/opexpr.aether",
    actions: OpExprTest.Actions
end
