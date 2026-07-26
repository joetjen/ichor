defmodule Grammar.Native.ForthTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp vm_grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.8 forth"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: vm_grammar()}
  end

  # A fresh context per input (no bootstrap needed) -- exercises the same
  # `Ichor.Capture` thunk semantics LISP does, on a flat,
  # non-tree-shaped grammar instead of LISP's recursive one.
  describe "run/2 parity with the VM backend" do
    for source <- [
          ": square dup * ;\n5 square",
          "5",
          "-3",
          "5 3 +",
          "5 3 -",
          "5 3 *",
          "6 3 /",
          "5 dup",
          "5 drop",
          "2 1 swap",
          "1 2 3",
          ": two 2 ;\ntwo two",
          ": never-called 1 0 / ;\n1"
        ] do
      test "#{inspect(source)}", %{grammar: g} do
        source = unquote(source)

        assert Native.Forth.run(source, Forth.Actions.new_context()) ==
                 Grammar.VM.run(g, source, Forth.Actions, Forth.Actions.new_context())
      end
    end
  end

  test "an unbound word yields a Ichor.Error on native too, not a crash" do
    assert {:error, %Ichor.Error{message: message}} =
             Native.Forth.run("unbound-word", Forth.Actions.new_context())

    assert message =~ "unbound word"
  end
end
