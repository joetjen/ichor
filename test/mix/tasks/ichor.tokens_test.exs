defmodule Mix.Tasks.Ichor.TokensTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  # A complete token listing needs checking against a nontrivial example,
  # so both SQL and HTTP are exercised here since each covers a different
  # shape: SQL overrides a predefined token (SPACE) and has no anonymous
  # tokens; HTTP has neither override nor anonymous tokens but does have
  # a multi-way literal choice (METHOD).

  test "lists every SQL token, in declaration/tie-break order" do
    output = run_on("4.5 sql")
    lines = split_rows(output)

    assert ["#", "NAME", "KIND", "PATTERN"] = hd(lines)

    rows = tl(lines)
    names = Enum.map(rows, &Enum.at(&1, 1))

    assert names == ~w(SELECT FROM WHERE STAR COMMA EQ NEQ LE GE LT GT IDENT STRING NUMBER SPACE
                        DIGIT ALPHA ALNUM HEX)

    # @case_insensitive desugars each letter of a literal to a two-char
    # class, so SELECT's pattern isn't a plain quoted string here.
    assert Enum.at(rows, 0) == ["1", "SELECT", "declared", "[sS] [eE] [lL] [eE] [cC] [tT]"]
    assert Enum.at(rows, 13) == ["14", "NUMBER", "declared", "DIGIT+"]
    assert Enum.find(rows, &(Enum.at(&1, 1) == "SPACE")) |> Enum.at(2) == "predefined"
  end

  test "lists every HTTP token, including the multi-way METHOD literal choice" do
    output = run_on("4.6 http")
    lines = split_rows(output)
    rows = tl(lines)

    method_row = Enum.find(rows, &(Enum.at(&1, 1) == "METHOD"))
    assert Enum.at(method_row, 2) == "declared"

    assert Enum.at(method_row, 3) ==
             ~s("GET" | "POST" | "PUT" | "DELETE" | "HEAD" | "OPTIONS" | "PATCH")

    names = Enum.map(rows, &Enum.at(&1, 1))
    assert names == ~w(METHOD SP HTTP_VERSION CRLF COLON WORD DIGIT ALPHA ALNUM SPACE HEX)
  end

  test "raises with a formatted Ichor.Error on a grammar that fails to parse" do
    path = write_grammar("not a valid grammar at all")

    assert_raise Mix.Error, ~r/expected|unexpected/i, fn ->
      capture_io(fn -> Mix.Tasks.Ichor.Tokens.run([path]) end)
    end
  end

  test "raises usage error when not given exactly one path" do
    assert_raise Mix.Error, ~r/usage/i, fn ->
      Mix.Tasks.Ichor.Tokens.run([])
    end
  end

  defp split_rows(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, ~r/\s{2,}/, trim: true))
  end

  defp run_on(example_name) do
    path = write_grammar(Support.ExampleGrammars.all()[example_name])
    capture_io(fn -> Mix.Tasks.Ichor.Tokens.run([path]) end)
  end

  defp write_grammar(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ichor_tokens_test_#{System.unique_integer([:positive])}.aether"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
