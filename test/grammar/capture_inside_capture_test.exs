defmodule Grammar.CaptureInsideCaptureTest do
  @moduledoc """
  What a capture over more than a bare reference holds, by every engine
  and both backends, lossless or not: its text, the captures inside it
  kept beside it, and **no implicit capture of a reference it directly
  wraps** -- in `sign:SIGN?` the name `sign` is the `SIGN`'s name, so
  the `SIGN` is not captured under its own name as well.
  """

  use ExUnit.Case, async: true

  defmodule NodeActions do
    @moduledoc "Answers the root rule's captures as their raw nodes."
    @behaviour Ichor.Actions

    @impl true
    def handle_rule(:r, captures, ctx) do
      {:ok,
       Map.new(captures, fn {name, cap} ->
         {name, if(is_list(cap), do: Enum.map(cap, & &1.node), else: cap.node)}
       end), ctx}
    end
  end

  @tokens ~S"""
  A    := "a"
  B    := "b"
  SIGN := "-"
  INT  := [0-9]+
  """

  defp source(engine, rules) do
    engine_line = if engine == :peg, do: "", else: "@engine #{engine}\n"
    "@grammar \"c\"\n@root r\n" <> engine_line <> @tokens <> rules
  end

  defp grammar(engine, rules) do
    {:ok, grammar} = Aether.Parser.parse(source(engine, rules), nil)
    grammar
  end

  defp run(engine, :interpreted, :ordinary, rules, input) do
    {:ok, analysed} = Grammar.Analysis.run(grammar(engine, rules))
    %{peg: Grammar.VM, lr: Grammar.LR, glr: Grammar.GLR}[engine].run(analysed, input, NodeActions)
  end

  defp run(engine, :interpreted, :lossless, rules, input) do
    {:ok, analysed} = Grammar.Analysis.run(grammar(engine, rules))

    %{peg: Grammar.VM, lr: Grammar.LR, glr: Grammar.GLR}[engine].run_lossless(
      analysed,
      input,
      NodeActions
    )
    |> without_tree()
  end

  defp run(engine, :compiled, mode, rules, input) do
    name = Module.concat(__MODULE__, "P#{System.unique_integer([:positive])}")
    code = Ichor.generate_from_grammar(grammar(engine, rules), NodeActions, lossless: true)
    Module.create(name, code, __ENV__)
    if mode == :lossless, do: without_tree(name.run_lossless(input)), else: name.run(input)
  end

  defp without_tree({:ok, value, _tree}), do: {:ok, value}
  defp without_tree(other), do: other

  for engine <- [:peg, :lr, :glr],
      backend <- [:interpreted, :compiled],
      mode <- [:ordinary, :lossless] do
    describe "#{engine}, #{backend}, #{mode}" do
      test "an optional token captured under a name is captured under that name only" do
        assert run(
                 unquote(engine),
                 unquote(backend),
                 unquote(mode),
                 "r := sign:SIGN? digits:INT\n",
                 "-12"
               ) ==
                 {:ok, %{sign: {:text, "-"}, digits: {:token, :INT, "12"}}}
      end

      test "an optional rule captured under its own name is one value, not two" do
        rules = "r := sign:sign? B\nsign := A\n"

        assert run(unquote(engine), unquote(backend), unquote(mode), rules, "ab") ==
                 {:ok, %{sign: {:text, "a"}, B: {:token, :B, "b"}}}
      end

      test "a repeated token captured under a name is captured under that name only" do
        assert run(unquote(engine), unquote(backend), unquote(mode), "r := many:A*\n", "aa") ==
                 {:ok, %{many: {:text, "aa"}}}
      end

      test "a group captured under a name keeps the captures inside it" do
        assert run(unquote(engine), unquote(backend), unquote(mode), "r := all:(k:A B)\n", "ab") ==
                 {:ok, %{all: {:text, "ab"}, k: {:token, :A, "a"}, B: {:token, :B, "b"}}}
      end
    end
  end

  # The reference a name owns is not captured, but it still matched: the
  # lossless tree keeps a node for every rule that did.
  test "the lossless tree keeps the rule a name owns" do
    {:ok, analysed} = Grammar.Analysis.run(grammar(:peg, "r := sign:sign? B\nsign := A\n"))
    {:ok, tree} = Grammar.VM.parse_lossless(analysed, "ab")
    assert Enum.map(tree.children, &Map.get(&1, :rule)) == [:sign, nil]
  end
end
