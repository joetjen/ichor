defmodule Native.Calculator do
  @moduledoc "The native-codegen backend's own worked example: `use Ichor` compiled against the exact same `4.1 calculator` fixture the VM backend's own tests use."

  use Ichor,
    grammar_source: Support.ExampleGrammars.all()["4.1 calculator"],
    actions: Calculator.Actions
end
