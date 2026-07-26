defmodule Native.Yaml do
  @moduledoc "Native-backend wiring for the `4.3 yaml` fixture -- the only example using `@indent`/`@samecol`, so this is the real regression check that both combinators work identically on the native backend."

  use Ichor,
    grammar_source: Support.ExampleGrammars.all()["4.3 yaml"],
    actions: Support.NoActions
end
