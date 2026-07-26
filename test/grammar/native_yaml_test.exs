defmodule Grammar.Native.YamlTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp vm_grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.3 yaml"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  defp vm_parse(input) do
    {:ok, node} = Grammar.VM.run(vm_grammar(), input, Support.NoActions)
    Yaml.Materialize.run(node)
  end

  defp native_parse(input) do
    {:ok, node} = Native.Yaml.run(input)
    Yaml.Materialize.run(node)
  end

  # YAML is the only one of the nine example grammars using
  # `@indent`/`@samecol` -- unlike the other native-backend tests (e.g.
  # calculator, which has no indentation combinators at all), this is the
  # real regression check that both combinators work identically on native.
  describe "@indent/@samecol parity with the VM backend" do
    for input <- [
          "name: ichor\ntags:\n  - grammar\n  - parser",
          "name: ichor\ntags:\n  - grammar\n  - parser\n",
          "a: 1\nb: 2",
          "hello world",
          "- a\n- b\n- c",
          "outer:\n  inner: 1\n  inner2: 2",
          "- a: 1\n  b: 2\n- c: 3",
          "- a: 1\n  tags:\n    - x\n    - y"
        ] do
      test "#{inspect(input)}" do
        input = unquote(input)
        assert native_parse(input) == vm_parse(input)
      end
    end
  end

  test "a line indented differently than its siblings is rejected on native too" do
    assert {:error, %Ichor.Error{}} = Native.Yaml.run("a: 1\n  b: 2")
  end
end
