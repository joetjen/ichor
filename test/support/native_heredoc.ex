defmodule Native.Heredoc do
  @moduledoc "Native-backend wiring for the `Ichor.CustomLexeme`/heredoc fixture."

  use Ichor,
    grammar: "../heredoc/heredoc.aether",
    actions: Support.NoActions
end
