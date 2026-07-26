defmodule Native.Lisp do
  @moduledoc "Native-backend wiring for the `4.2 lisp` fixture -- proves `run_sequence/2` (needed to load `stdlib.lisp`) works identically to `Grammar.VM.run_sequence/4`."

  use Ichor,
    grammar_source: Support.ExampleGrammars.all()["4.2 lisp"],
    actions: Lisp.Actions
end
