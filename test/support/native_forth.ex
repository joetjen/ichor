defmodule Native.Forth do
  @moduledoc "Native-backend wiring for the `4.8 forth` fixture -- a second exercise (alongside LISP) of `Ichor.Capture` thunk semantics on the native backend."

  use Ichor,
    grammar_source: Support.ExampleGrammars.all()["4.8 forth"],
    actions: Forth.Actions
end
