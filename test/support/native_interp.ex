defmodule Native.Interp do
  @moduledoc "Native-backend wiring for the `Ichor.CustomLexeme` string-interpolation fixture."

  use Ichor,
    grammar: "../interp/interp.aether",
    actions: InterpTest.Actions
end
