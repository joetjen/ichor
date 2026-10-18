defmodule Ichor.ConformanceTest do
  @moduledoc """
  `Ichor.Conformance` — this implementation's answers to a batch of
  Ichor Conformance Suite cases, through either backend, in the
  shape the suite reads; and `mix ichor.conformance`, which reads and
  writes them as files.
  """

  use ExUnit.Case, async: true

  alias Ichor.Conformance

  @moduletag :tmp_dir

  @calculator ~S"""
  @grammar "calculator"
  @root expr

  NUMBER := /\d+(\.\d+)?/
  SPACE  := [ \t\n]+

  expr   := term (op:("+" | "-") term)*
  term   := factor (op:("*" | "/") factor)*
  factor := NUMBER | "(" expr ")"
  """

  @left_sum ~S"""
  @grammar "left_sum"
  @root expr
  @engine lr

  NUMBER := /\d+/
  PLUS   := "+"

  expr := expr PLUS term | term
  term := NUMBER
  """

  defp grammar(dir, name, source) do
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end

  defp answer(backend, cases) do
    %{"results" => results} = Conformance.answer(%{"cases" => cases}, backend)
    results
  end

  defp parse(id, grammar, text),
    do: %{"id" => id, "operation" => "parse", "grammar" => grammar, "text" => text}

  defp node(rule, captures),
    do: %{"tuple" => [%{"keyword" => "node"}, %{"keyword" => rule}, %{"map" => captures}]}

  # `2`, as the calculator's default tree.
  defp two do
    node("expr", [
      [%{"keyword" => "op"}, []],
      [
        %{"keyword" => "term"},
        [node("term", [[%{"keyword" => "factor"}, ["2"]], [%{"keyword" => "op"}, []]])]
      ]
    ])
  end

  for backend <- [:interpreted, :compiled] do
    describe "the #{backend} backend" do
      test "answers a parse with its default tree, as typed data", %{tmp_dir: dir} do
        path = grammar(dir, "calculator.aether", @calculator)

        assert [%{"id" => "a", "tree" => tree}] =
                 answer(unquote(backend), [parse("a", path, "2")])

        assert sorted(tree) == sorted(two())
      end

      test "answers a parse that fails with its stage, line and column", %{tmp_dir: dir} do
        path = grammar(dir, "calculator.aether", @calculator)

        assert [%{"id" => "a", "error" => error}] =
                 answer(unquote(backend), [parse("a", path, "2 +")])

        assert sorted(error) ==
                 sorted(%{
                   "map" => [
                     [%{"keyword" => "stage"}, %{"keyword" => "parser"}],
                     [%{"keyword" => "line"}, %{"integer" => "1"}],
                     [%{"keyword" => "column"}, %{"integer" => "3"}]
                   ]
                 })
      end

      test "runs a grammar of another engine", %{tmp_dir: dir} do
        path = grammar(dir, "left-sum.aether", @left_sum)

        assert [%{"id" => "a", "tree" => _}] =
                 answer(unquote(backend), [parse("a", path, "1+2+3")])
      end

      test "answers a grammar that does not analyse as an analysis error", %{tmp_dir: dir} do
        path = grammar(dir, "broken.aether", "@grammar \"broken\"\n@root a\n\na := b\n")

        assert [%{"id" => "a", "error" => %{"map" => pairs}}] =
                 answer(unquote(backend), [parse("a", path, "x")])

        assert [%{"keyword" => "stage"}, %{"keyword" => "analysis"}] in pairs
      end

      test "answers every case, in order", %{tmp_dir: dir} do
        path = grammar(dir, "calculator.aether", @calculator)

        ids =
          unquote(backend)
          |> answer([parse("one", path, "1"), parse("two", path, "("), parse("three", path, "3")])
          |> Enum.map(& &1["id"])

        assert ids == ["one", "two", "three"]
      end
    end
  end

  # The same language -- a number, or two joined by `+` -- in each
  # notation Ichor reads, all `@noskip` as an import always is.
  @notations %{
    "sum.peg" => "sum <- num ('+' num)?\nnum <- [0-9]+\n",
    "sum.bnf" => "<sum> ::= <num> '+' <num> | <num>\n<num> ::= '1' | '2'\n",
    "sum.ebnf" => "sum = num, ['+', num] ;\nnum = '1' | '2' ;\n",
    "sum.abnf" => "sum = num [\"+\" num]\r\nnum = \"1\" / \"2\"\r\n",
    "sum.w3c.ebnf" => "sum ::= num ('+' num)?\nnum ::= '1' | '2'\n"
  }

  for {name, source} <- @notations, backend <- [:interpreted, :compiled] do
    test "#{backend}: a grammar written as #{name} is read by its importer",
         %{tmp_dir: dir} do
      path = grammar(dir, unquote(name), unquote(source))

      assert [%{"id" => "a", "tree" => _}] = answer(unquote(backend), [parse("a", path, "1+2")])
      assert [%{"id" => "a", "error" => _}] = answer(unquote(backend), [parse("a", path, "1+")])
    end
  end

  test "an @style line names the notation whatever the extension", %{tmp_dir: dir} do
    path = grammar(dir, "sum.txt", "@style peg\n" <> @notations["sum.peg"])
    assert [%{"tree" => _}] = answer(:compiled, [parse("a", path, "12")])
  end

  defp tokens_case(id, grammar, text),
    do: %{"id" => id, "operation" => "tokens", "grammar" => grammar, "text" => text}

  defp token(name, text, line, column),
    do: %{
      "tuple" => [
        name && %{"keyword" => name},
        text,
        %{"integer" => Integer.to_string(line)},
        %{"integer" => Integer.to_string(column)}
      ]
    }

  for backend <- [:interpreted, :compiled] do
    # An inline literal's token has no name its author chose -- `ANON_1`
    # is generated, and the suite never compares a generated name -- so
    # it is written with the name nil, and known by its text.
    test "#{backend}: tokens answers the stream, trivia included, as #(NAME text line column)",
         %{tmp_dir: dir} do
      path = grammar(dir, "calculator.aether", @calculator)

      assert [%{"id" => "a", "tokens" => tokens}] =
               answer(unquote(backend), [tokens_case("a", path, "2 +\n3")])

      assert tokens == [
               token("NUMBER", "2", 1, 1),
               token("SPACE", " ", 1, 2),
               token(nil, "+", 1, 3),
               token("SPACE", "\n", 1, 4),
               token("NUMBER", "3", 2, 1)
             ]
    end

    test "#{backend}: tokens answers a character no token matches as a lexer error",
         %{tmp_dir: dir} do
      path = grammar(dir, "calculator.aether", @calculator)

      assert [%{"id" => "a", "error" => %{"map" => pairs}}] =
               answer(unquote(backend), [tokens_case("a", path, "2 $")])

      assert [%{"keyword" => "stage"}, %{"keyword" => "lexer"}] in pairs
      assert [%{"keyword" => "column"}, %{"integer" => "3"}] in pairs
    end
  end

  test "the two backends agree on a nested tree", %{tmp_dir: dir} do
    path = grammar(dir, "calculator.aether", @calculator)
    cases = [parse("a", path, "(1 + 2) * 3 - 4")]

    assert sorted(answer(:interpreted, cases)) == sorted(answer(:compiled, cases))
  end

  test "an operation it does not know is answered as an error naming it", %{tmp_dir: _} do
    assert [%{"id" => "a", "error" => "unsupported operation \"fly\""}] =
             answer(:interpreted, [%{"id" => "a", "operation" => "fly"}])
  end

  describe "mix ichor.conformance" do
    test "reads a request file and writes the answer file", %{tmp_dir: dir} do
      path = grammar(dir, "calculator.aether", @calculator)
      request = Path.join(dir, "request.json")
      answer = Path.join(dir, "answer.json")
      File.write!(request, JSON.encode!(%{"cases" => [parse("a", path, "2")]}))

      Mix.Tasks.Ichor.Conformance.run(["compiled", request, answer])

      assert %{"results" => [%{"id" => "a", "tree" => tree}]} = JSON.decode!(File.read!(answer))
      assert sorted(tree) == sorted(two())
    end

    test "without a backend and both paths it raises a usage error", %{tmp_dir: _} do
      assert_raise Mix.Error,
                   ~r/usage: mix ichor.conformance interpreted\|compiled REQUEST ANSWER/,
                   fn ->
                     Mix.Tasks.Ichor.Conformance.run([])
                   end
    end

    test "a backend it does not know is a usage error", %{tmp_dir: _} do
      assert_raise Mix.Error, ~r/usage/, fn ->
        Mix.Tasks.Ichor.Conformance.run(["quantum", "r", "a"])
      end
    end
  end

  # A map's pairs travel in whatever order the map enumerates, which the
  # suite does not care about and these tests should not either.
  defp sorted(%{"map" => pairs}), do: %{"map" => pairs |> Enum.map(&sorted/1) |> Enum.sort()}
  defp sorted(%{"tuple" => items}), do: %{"tuple" => Enum.map(items, &sorted/1)}
  defp sorted(%{} = map), do: Map.new(map, fn {k, v} -> {k, sorted(v)} end)
  defp sorted(list) when is_list(list), do: Enum.map(list, &sorted/1)
  defp sorted(other), do: other
end
