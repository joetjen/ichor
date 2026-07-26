defmodule Native.HTTP do
  @moduledoc "Native-backend wiring for the `4.6 http` fixture -- exercises `@noskip` and a text capture over an alternation (`body`'s `content:((WORD | SP | COLON | CRLF)*)`)."

  use Ichor,
    grammar_source: Support.ExampleGrammars.all()["4.6 http"],
    actions: HTTP.Actions
end
