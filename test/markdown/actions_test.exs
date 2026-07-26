defmodule Markdown.ActionsTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.9 markdown"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: grammar()}
  end

  defp run(grammar, source), do: Grammar.VM.run(grammar, source, Markdown.Actions)

  describe "the markdown worked example" do
    test "heading, list, and a paragraph with bold + link segments, in order", %{grammar: g} do
      input = "# Hello\n\n- one\n- two\n\nSome **bold** text with a [link](https://example.com)."

      assert {:ok,
              "<h1>Hello</h1>\n" <>
                "<ul><li>one</li><li>two</li></ul>\n" <>
                ~S(<p>Some <strong>bold</strong> text with a <a href="https://example.com">link</a>.</p>)} =
               run(g, input)
    end
  end

  describe "headings" do
    test "heading level matches the number of #s", %{grammar: g} do
      assert {:ok, "<h1>One</h1>"} = run(g, "# One")
      assert {:ok, "<h2>Two</h2>"} = run(g, "## Two")
      assert {:ok, "<h3>Three</h3>"} = run(g, "### Three")
    end
  end

  describe "lists" do
    test "a single item", %{grammar: g} do
      assert {:ok, "<ul><li>only</li></ul>"} = run(g, "- only")
    end

    test "multiple items stay in order", %{grammar: g} do
      assert {:ok, "<ul><li>a</li><li>b</li><li>c</li></ul>"} = run(g, "- a\n- b\n- c")
    end
  end

  describe "paragraphs" do
    test "plain text with no formatting", %{grammar: g} do
      assert {:ok, "<p>just text</p>"} = run(g, "just text")
    end

    test "bold segments", %{grammar: g} do
      assert {:ok, "<p><strong>all bold</strong></p>"} = run(g, "**all bold**")
    end

    test "link segments", %{grammar: g} do
      assert {:ok, ~S(<p><a href="https://x.test">x</a></p>)} = run(g, "[x](https://x.test)")
    end

    test "interleaved plain/bold/link segments preserve their original order", %{grammar: g} do
      assert {:ok, ~S(<p>a <strong>b</strong> c <a href="d">e</a> f</p>)} =
               run(g, "a **b** c [e](d) f")
    end
  end

  describe "multiple blocks" do
    test "blocks are joined with newlines, in document order", %{grammar: g} do
      assert {:ok, "<h1>A</h1>\n<p>B</p>\n<ul><li>c</li></ul>"} = run(g, "# A\n\nB\n\n- c")
    end
  end
end
