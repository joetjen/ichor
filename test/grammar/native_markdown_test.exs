defmodule Grammar.Native.MarkdownTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp vm_grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.9 markdown"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: vm_grammar()}
  end

  describe "run/1 parity with the VM backend" do
    for source <- [
          "# Hello\n\n- one\n- two\n\nSome **bold** text with a [link](https://example.com).",
          "# One",
          "## Two",
          "### Three",
          "- only",
          "- a\n- b\n- c",
          "just text",
          "**all bold**",
          "[x](https://x.test)",
          "a **b** c [e](d) f",
          "# A\n\nB\n\n- c"
        ] do
      test "#{inspect(source)}", %{grammar: g} do
        source = unquote(source)
        assert Native.Markdown.run(source) == Grammar.VM.run(g, source, Markdown.Actions)
      end
    end
  end
end
