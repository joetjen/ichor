defmodule Grammar.LosslessTest do
  @moduledoc """
  The lossless mode (`design/lossless-mode.md`): every engine and both
  backends build the same full-fidelity tree from the same grammar, give
  back the input byte for byte, and decide exactly as the ordinary
  parser does -- the same value, the same errors.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ichor.Syntax
  alias Ichor.Syntax.Node

  @grammars %{
    peg: ~S"""
    @grammar "pairs"
    @root doc
    @skip TRIVIA
    SPACE   := [ \t\n]+
    COMMENT := "#" (!"\n" .)* "\n"?
    TRIVIA  := (SPACE | COMMENT)+
    KEY     := [a-z]+
    NUM     := [0-9]+
    doc   := entry*
    entry := key:KEY ":" value
    value := NUM | list
    list  := "[" value* "]"
    """,
    lr: ~S"""
    @grammar "pairs"
    @root doc
    @engine lr
    @skip WS
    WS  := [ \t\n]+
    KEY := [a-z]+
    NUM := [0-9]+
    doc   := entry+
    entry := key:KEY ":" NUM
    """,
    glr: File.read!(Path.join(__DIR__, "../dangling_else/dangling_else.aether"))
  }

  @inputs %{
    peg: [
      "a: 1",
      "a: 1 # one\nb: [2 3]\n",
      "# leading\n\na:[ ]  # trailing",
      "x: [[1] [] 2]",
      "",
      "  # nothing but a comment\n"
    ],
    lr: ["a: 1", "  a:1\nb : 2 \n", "a:1 b:2 c:3"],
    glr: ["if a then 1", " if a then if b then 1 else 2\n", "7"]
  }

  @bad %{peg: "a: ]", lr: "a: :", glr: "if then"}

  defp grammar(engine) do
    {:ok, grammar} = Aether.Parser.parse(@grammars[engine], nil)
    grammar
  end

  defp interpreted(engine), do: %{peg: Grammar.VM, lr: Grammar.LR, glr: Grammar.GLR}[engine]

  # One generated module per engine, made once: `lossless: true`.
  defp compiled(engine) do
    name = Module.concat(__MODULE__, "Lossless#{engine}")

    unless Code.ensure_loaded?(name) do
      code = Ichor.generate_from_grammar(grammar(engine), Support.NoActions, lossless: true)
      Module.create(name, code, __ENV__)
    end

    name
  end

  defp parse_lossless(engine, :interpreted, input) do
    {:ok, analysed} = Grammar.Analysis.run(grammar(engine))
    interpreted(engine).parse_lossless(analysed, input)
  end

  defp parse_lossless(engine, :compiled, input), do: compiled(engine).parse_lossless(input)

  defp run_lossless(engine, :interpreted, input) do
    {:ok, analysed} = Grammar.Analysis.run(grammar(engine))
    interpreted(engine).run_lossless(analysed, input, Support.NoActions)
  end

  defp run_lossless(engine, :compiled, input), do: compiled(engine).run_lossless(input)

  defp run(engine, :interpreted, input) do
    {:ok, analysed} = Grammar.Analysis.run(grammar(engine))
    interpreted(engine).run(analysed, input, Support.NoActions)
  end

  defp run(engine, :compiled, input), do: compiled(engine).run(input)

  # A tree read at a glance: rules, token texts, and trivia marked.
  defp shape(%Node{rule: rule, children: children}), do: {rule, Enum.map(children, &shape/1)}
  defp shape(%Syntax.Token{trivia: true, text: text}), do: {:trivia, text}
  defp shape(%Syntax.Token{text: text}), do: text

  for engine <- [:peg, :lr, :glr], backend <- [:interpreted, :compiled] do
    describe "#{engine}, #{backend}" do
      for input <- @inputs[engine] do
        test "gives back #{inspect(input)} byte for byte" do
          assert {:ok, tree} = parse_lossless(unquote(engine), unquote(backend), unquote(input))
          assert Syntax.text(tree) == unquote(input)
        end

        test "runs #{inspect(input)} to the value the ordinary parser gives" do
          {:ok, value} = run(unquote(engine), unquote(backend), unquote(input))

          assert {:ok, ^value, %Node{}} =
                   run_lossless(unquote(engine), unquote(backend), unquote(input))
        end
      end

      test "fails as the ordinary parser fails, word for word" do
        bad = @bad[unquote(engine)]
        {:error, error} = run(unquote(engine), unquote(backend), bad)

        assert parse_lossless(unquote(engine), unquote(backend), bad) == {:error, error}
      end
    end
  end

  describe "the tree" do
    test "puts every token under the deepest rule that matched it, trivia between" do
      {:ok, tree} = parse_lossless(:peg, :interpreted, "a: 1 # one\nb: [2 3]\n")

      assert shape(tree) ==
               {:doc,
                [
                  {:entry, ["a", ":", {:trivia, " "}, {:value, ["1"]}]},
                  {:trivia, " # one\n"},
                  {:entry,
                   [
                     "b",
                     ":",
                     {:trivia, " "},
                     {:value,
                      [{:list, ["[", {:value, ["2"]}, {:trivia, " "}, {:value, ["3"]}, "]"]}]}
                   ]},
                  {:trivia, "\n"}
                ]}
    end

    test "gives the root the trivia around the input" do
      {:ok, tree} = parse_lossless(:peg, :interpreted, "# c\na: 1 ")

      assert [{:trivia, "# c\n"}, {:entry, _}, {:trivia, " "}] = elem(shape(tree), 1)
    end

    test "of an LR grammar holds the rules the grammar wrote, not the helpers desugaring made" do
      {:ok, tree} = parse_lossless(:lr, :interpreted, "a:1 b:2")

      assert shape(tree) ==
               {:doc, [{:entry, ["a", ":", "1"]}, {:trivia, " "}, {:entry, ["b", ":", "2"]}]}
    end

    test "of a GLR grammar follows the derivation the ordinary parse picks" do
      {:ok, tree} = parse_lossless(:glr, :interpreted, "if a then if b then 1 else 2")

      # The `else` binds to the inner `if`, as `Support.DanglingElseActions`
      # shows the ordinary parse deciding.
      assert {:stmt, [{:if_stmt, ["if", _, "a", _, "then", _, {:stmt, [inner]}]}]} = shape(tree)
      assert {:if_stmt, ["if", _, "b", _, "then", _, _, _, "else", _, _]} = inner
    end

    for engine <- [:peg, :lr, :glr], input <- @inputs[engine] do
      test "#{engine}: the same from both backends for #{inspect(input)}" do
        assert parse_lossless(unquote(engine), :interpreted, unquote(input)) ==
                 parse_lossless(unquote(engine), :compiled, unquote(input))
      end
    end

    property "gives back any document, the same from both backends" do
      check all(input <- document()) do
        assert {:ok, tree} = parse_lossless(:peg, :interpreted, input)
        assert Syntax.text(tree) == input
        assert parse_lossless(:peg, :compiled, input) == {:ok, tree}
      end
    end
  end

  describe "without lossless: true" do
    test "a generated parser has no lossless functions" do
      name = Module.concat(__MODULE__, "Ordinary")
      Module.create(name, Ichor.generate_from_grammar(grammar(:peg), Support.NoActions), __ENV__)

      refute function_exported?(name, :parse_lossless, 1)
      refute function_exported?(name, :run_lossless, 1)
      assert function_exported?(name, :parse, 1)
    end
  end

  # A `pairs` document: entries, with trivia of any kind around and
  # between every token -- where the grammar allows it.
  defp document do
    gap = StreamData.member_of(["", " ", "\n", " # c\n", "#\n\n  "])

    value =
      StreamData.tree(StreamData.member_of(["1", "42"]), fn inner ->
        gen all(
              items <- StreamData.list_of(StreamData.tuple({gap, inner}), max_length: 3),
              close <- gap
            ) do
          "[" <> Enum.map_join(items, "", fn {g, v} -> g <> v end) <> close <> "]"
        end
      end)

    gen all(
          lead <- gap,
          entries <-
            StreamData.list_of(
              StreamData.tuple({StreamData.member_of(["a", "key"]), gap, gap, value, gap}),
              max_length: 4
            ),
          trail <- gap
        ) do
      body =
        Enum.map_join(entries, "", fn {key, g1, g2, v, g3} ->
          key <> g1 <> ":" <> g2 <> v <> g3 <> " "
        end)

      lead <> body <> trail
    end
  end
end
