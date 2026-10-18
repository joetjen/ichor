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
