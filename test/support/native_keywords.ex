defmodule Native.Keywords do
  @moduledoc "Native-backend wiring for the `@keywords`/`@refine` fixture."

  use Ichor,
    grammar: "../keywords/keywords.aether",
    actions: KeywordsTest.Actions
end
