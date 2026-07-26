defmodule Native.Regex do
  @moduledoc "Native-backend wiring for the `4.7 regex` fixture."

  use Ichor,
    grammar_source: Support.ExampleGrammars.all()["4.7 regex"],
    actions: Regex.Actions
end
