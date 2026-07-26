defmodule Native.Markdown do
  @moduledoc "Native-backend wiring for the `4.9 markdown` fixture."

  use Ichor,
    grammar_source: Support.ExampleGrammars.all()["4.9 markdown"],
    actions: Markdown.Actions
end
