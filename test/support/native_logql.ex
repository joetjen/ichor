defmodule Native.LogQL do
  @moduledoc "Native-backend wiring for the `4.4 logql` fixture."

  use Ichor,
    grammar_source: Support.ExampleGrammars.all()["4.4 logql"],
    actions: LogQL.Actions
end
