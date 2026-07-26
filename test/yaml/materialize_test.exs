defmodule Yaml.MaterializeTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.3 yaml"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: grammar()}
  end

  # "Zero custom actions" is the point here: `Support.NoActions`
  # implements none of `Ichor.Actions`'s optional callbacks, so this is
  # the default fallback alone -- with no custom Actions module at all,
  # the default fallback alone produces the equivalent of %{...}.
  defp parse(grammar, input) do
    {:ok, node} = Grammar.VM.run(grammar, input, Support.NoActions)
    Yaml.Materialize.run(node)
  end

  describe "the yaml worked example" do
    test "nested mapping/sequence produces the correct map/list", %{grammar: g} do
      assert %{"name" => "ichor", "tags" => ["grammar", "parser"]} =
               parse(g, "name: ichor\ntags:\n  - grammar\n  - parser")
    end

    test "also works with a trailing newline, as most real files have", %{grammar: g} do
      assert %{"name" => "ichor", "tags" => ["grammar", "parser"]} =
               parse(g, "name: ichor\ntags:\n  - grammar\n  - parser\n")
    end
  end

  describe "flat mapping" do
    test "two sibling pairs at the same column", %{grammar: g} do
      assert %{"a" => "1", "b" => "2"} = parse(g, "a: 1\nb: 2")
    end

    test "a single pair" do
      assert %{"a" => "1"} = parse(grammar(), "a: 1")
    end
  end

  describe "bare scalar document" do
    test "no mapping or sequence at all, just a scalar", %{grammar: g} do
      assert "hello world" = parse(g, "hello world")
    end
  end

  describe "bare sequence document" do
    test "a top-level sequence with no enclosing mapping", %{grammar: g} do
      assert ["a", "b", "c"] = parse(g, "- a\n- b\n- c")
    end
  end

  describe "nesting" do
    test "a mapping nested inside a mapping's value", %{grammar: g} do
      assert %{"outer" => %{"inner" => "1", "inner2" => "2"}} =
               parse(g, "outer:\n  inner: 1\n  inner2: 2")
    end

    test "a mapping nested inside a sequence item", %{grammar: g} do
      assert [%{"a" => "1", "b" => "2"}, %{"c" => "3"}] =
               parse(g, "- a: 1\n  b: 2\n- c: 3")
    end

    test "a sequence nested inside a mapping value nested inside a sequence item", %{grammar: g} do
      assert [%{"a" => "1", "tags" => ["x", "y"]}] =
               parse(g, "- a: 1\n  tags:\n    - x\n    - y")
    end
  end

  describe "indentation discipline" do
    test "a line indented differently than its siblings is rejected" do
      assert {:error, %Ichor.Error{}} =
               Grammar.VM.run(grammar(), "a: 1\n  b: 2", Support.NoActions)
    end
  end
end
