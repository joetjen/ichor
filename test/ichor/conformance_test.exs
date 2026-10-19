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

  defp lossless_case(id, grammar, text),
    do: %{"id" => id, "operation" => "lossless", "grammar" => grammar, "text" => text}

  defp kw(name), do: %{"keyword" => name}
  defp int(n), do: %{"integer" => Integer.to_string(n)}

  defp rule(name, offset, size, line, column, children),
    do: %{
      "tuple" => [kw("rule"), kw(name), int(offset), int(size), int(line), int(column), children]
    }

  defp leaf(name, text, trivia, offset, line, column),
    do: %{
      "tuple" => [
        kw("token"),
        if(name, do: kw(name)),
        text,
        trivia,
        int(offset),
        int(line),
        int(column)
      ]
    }

  for backend <- [:interpreted, :compiled] do
    # The lossless tree as the suite writes it: a node as
    # #(:rule name offset size line column [children]), a token as
    # #(:token name text trivia offset line column) -- every field an
    # implementation computes, so the offsets are held to the same
    # cases as the structure.
    test "#{backend}: lossless answers the tree, every token under the rule that matched it",
         %{tmp_dir: dir} do
      path = grammar(dir, "left_sum.aether", @left_sum)

      assert answer(unquote(backend), [lossless_case("a", path, "1+2")]) == [
               %{
                 "id" => "a",
                 "tree" =>
                   rule("expr", 0, 3, 1, 1, [
                     rule("expr", 0, 1, 1, 1, [
                       rule("term", 0, 1, 1, 1, [leaf("NUMBER", "1", false, 0, 1, 1)])
                     ]),
                     leaf("PLUS", "+", false, 1, 1, 2),
                     rule("term", 2, 1, 1, 3, [leaf("NUMBER", "2", false, 2, 1, 3)])
                   ])
               }
             ]
    end

    test "#{backend}: lossless names an inline literal's token nil and marks trivia",
         %{tmp_dir: dir} do
      path = grammar(dir, "calculator.aether", @calculator)

      assert [%{"id" => "a", "tree" => %{"tuple" => [_, _, _, _, _, _, children]}}] =
               answer(unquote(backend), [lossless_case("a", path, "2 +3")])

      assert leaf("SPACE", " ", true, 1, 1, 2) in children
      assert leaf(nil, "+", false, 2, 1, 3) in children
    end

    test "#{backend}: lossless answers what does not parse as its error", %{tmp_dir: dir} do
      path = grammar(dir, "calculator.aether", @calculator)

      assert [%{"id" => "a", "error" => %{"map" => pairs}}] =
               answer(unquote(backend), [lossless_case("a", path, "2 +")])

      assert [%{"keyword" => "stage"}, %{"keyword" => "parser"}] in pairs
    end
  end

  defp render_case(id, grammar, text),
    do: %{"id" => id, "operation" => "render", "grammar" => grammar, "text" => text}

  for backend <- [:interpreted, :compiled] do
    test "#{backend}: render answers the first error as Ichor.Error.format/1 writes it",
         %{tmp_dir: dir} do
      path = grammar(dir, "calculator.aether", @calculator)

      assert answer(unquote(backend), [render_case("a", path, "2 +")]) == [
               %{
                 "id" => "a",
                 "rendered" =>
                   "1:3: unexpected \"+\" -- did not expect more input here\n1 | 2 +\n  |   ^"
               }
             ]
    end

    test "#{backend}: render answers an input that parses with its tree", %{tmp_dir: dir} do
      path = grammar(dir, "calculator.aether", @calculator)

      assert [%{"id" => "a", "tree" => _}] =
               answer(unquote(backend), [render_case("a", path, "2")])
    end
  end

  describe "the toolkits" do
    # Typed JSON for the few shapes these cases need.
    defp kw(name), do: %{"keyword" => name}
    defp int(n), do: %{"integer" => Integer.to_string(n)}
    defp tup(items), do: %{"tuple" => items}
    defp map_of(pairs), do: %{"map" => pairs}
    defp var(name), do: tup([kw("var"), name])
    defp term(f, args), do: tup([kw("term"), f, args])

    defp toolkit(operation, fields),
      do: answer(:interpreted, [Map.merge(%{"id" => "a", "operation" => operation}, fields)])

    test "pratt answers precedence, associativity and every fixity as a tree", %{tmp_dir: _} do
      operators =
        map_of([
          ["-", map_of([[kw("prefix"), int(9)], [kw("infix"), [int(5), kw("left")]]])],
          ["^", map_of([[kw("infix"), [int(7), kw("right")]]])],
          ["!", map_of([[kw("postfix"), int(8)]])]
        ])

      assert [%{"tree" => tree}] =
               toolkit("pratt", %{
                 "operators" => operators,
                 "tokens" => ["-", "1", "-", "2", "!", "^", "3"]
               })

      assert tree ==
               tup([
                 kw("infix"),
                 "-",
                 tup([kw("prefix"), "-", "1"]),
                 tup([kw("infix"), "^", tup([kw("postfix"), "!", "2"]), "3"])
               ])
    end

    test "pratt answers what it could not read as an error", %{tmp_dir: _} do
      operators = map_of([["+", map_of([[kw("infix"), [int(5), kw("left")]]])]])

      assert [%{"error" => tup([kw("left-over"), int(1)])}] ==
               toolkit("pratt", %{"operators" => operators, "tokens" => ["1", "2"]})
               |> Enum.map(&Map.delete(&1, "id"))

      assert [%{"error" => kw("fail")}] ==
               toolkit("pratt", %{"operators" => operators, "tokens" => ["+"]})
               |> Enum.map(&Map.delete(&1, "id"))
    end

    test "unify answers the bindings it made, or fail", %{tmp_dir: _} do
      assert [%{"result" => %{"map" => pairs}}] =
               toolkit("unify", %{
                 "left" => term("f", [var("X"), "b"]),
                 "right" => term("f", ["a", var("Y")]),
                 "occurs-check" => false
               })

      assert Enum.sort(pairs) == Enum.sort([["X", "a"], ["Y", "b"]])

      assert [%{"result" => kw("fail")}] ==
               toolkit("unify", %{"left" => "a", "right" => "b", "occurs-check" => false})
               |> Enum.map(&Map.delete(&1, "id"))
    end

    test "unify with the occurs check refuses a variable inside itself", %{tmp_dir: _} do
      fields = %{"left" => var("X"), "right" => term("f", [var("X")])}

      assert [%{"result" => kw("fail")}] ==
               toolkit("unify", Map.put(fields, "occurs-check", true))
               |> Enum.map(&Map.delete(&1, "id"))

      assert [%{"result" => %{"map" => [_]}}] =
               toolkit("unify", Map.put(fields, "occurs-check", false))
               |> Enum.map(&Map.delete(&1, "id"))
    end

    test "solve answers every solution, in order, and once keeps the first", %{tmp_dir: _} do
      either =
        tup([kw("or"), tup([kw("unify"), var("X"), "a"]), tup([kw("unify"), var("X"), "b"])])

      assert [%{"solutions" => [%{"map" => [["X", "a"]]}, %{"map" => [["X", "b"]]}]}] =
               toolkit("solve", %{"goal" => either}) |> Enum.map(&Map.delete(&1, "id"))

      assert [%{"solutions" => [%{"map" => [["X", "a"]]}]}] =
               toolkit("solve", %{"goal" => tup([kw("once"), either])})
               |> Enum.map(&Map.delete(&1, "id"))
    end

    test "walk visits a node before its children, and renames functors", %{tmp_dir: _} do
      t = term("f", [term("g", ["a"]), "b"])

      assert [%{"result" => [^t, %{"tuple" => _}, "a", "b"]}] =
               toolkit("walk", %{"term" => t, "walk" => kw("visit")})
               |> Enum.map(&Map.delete(&1, "id"))

      rename = tup([kw("rename"), map_of([["g", "h"]])])

      assert [%{"result" => renamed}] =
               toolkit("walk", %{"term" => t, "walk" => rename})
               |> Enum.map(&Map.delete(&1, "id"))

      assert renamed == term("f", [term("h", ["a"]), "b"])
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
