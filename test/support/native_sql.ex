defmodule Native.SQL do
  @moduledoc "Native-backend wiring for the `4.5 sql` fixture -- also exercises `@case_insensitive` on the native backend."

  use Ichor,
    grammar_source: Support.ExampleGrammars.all()["4.5 sql"],
    actions: SQL.Actions
end
