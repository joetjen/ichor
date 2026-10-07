defmodule Aether.GrammarDocTest do
  @moduledoc """
  Keeps `guides/aether/AETHER_GRAMMAR.md` true. The guide states Aether's
  syntax as an Aether grammar, but nothing reads `.aether` files with it
  -- `Aether.Reader` is hand-written -- so without this test the two
  could drift apart and the guide would never say so.

  The grammar is taken from the guide itself, so there is one copy.
  """
  use ExUnit.Case, async: true

  @guide "guides/aether/AETHER_GRAMMAR.md"
  @external_resource @guide

  setup_all do
    [_, block] = Regex.run(~r/```text\n(.*?)```/s, File.read!(@guide))
    {:ok, grammar} = Aether.Parser.parse(block, @guide)
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    %{grammar: grammar}
  end

  defp reader_accepts?(source), do: match?({:ok, _}, Aether.Reader.read(source))
  defp grammar_accepts?(grammar, source), do: match?({:ok, _}, Grammar.VM.parse(grammar, source))

  test "the guide holds exactly one grammar block" do
    assert @guide |> File.read!() |> String.split("```text") |> length() == 2
  end

  test "agrees with Aether.Reader on every .aether file in this repository", %{grammar: grammar} do
    files = Path.wildcard("priv/grammar/*.aether") ++ Path.wildcard("test/**/*.aether")
    assert length(files) >= 20

    for file <- files do
      source = File.read!(file)

      assert grammar_accepts?(grammar, source) == reader_accepts?(source),
             "#{file}: Aether.Reader says #{reader_accepts?(source)}, the guide's grammar says #{grammar_accepts?(grammar, source)}"
    end
  end

  # Broken in ways that are pure syntax, so both must refuse them.
  @syntax_errors [
    no_root: ~s(@grammar "x"\nA := "a"\n),
    root_first: ~s(@root a\n@grammar "x"\na := "a"\n),
    mixed_case_name: ~s(@grammar "x"\n@root a\nFoo := "a"\na := Foo\n),
    unknown_pragma: ~s(@grammar "x"\n@root a\n@foo\na := "a"\n),
    pragma_after_definitions: ~s(@grammar "x"\n@root a\na := "a"\n@skip SPACE\n),
    bound_without_minimum: ~s(@grammar "x"\n@root a\na := "a"{,3}\n),
    unterminated_string: ~s(@grammar "x"\n@root a\na := "a\n),
    bad_string_suffix: ~s(@grammar "x"\n@root a\na := "a"is\n)
  ]

  for {name, source} <- @syntax_errors do
    test "both refuse #{name}", %{grammar: grammar} do
      source = unquote(source)
      refute reader_accepts?(source)
      refute grammar_accepts?(grammar, source)
    end
  end

  test "both accept a grammar using every construct", %{grammar: grammar} do
    source = ~S"""
    ; leading comment
    @grammar "everything"
    @root a
    @engine peg
    @case_insensitive

    a := @native("M", "f", b) @hint(nullable: false, leading: (b)) | b
    b := key:X "c"i{2,} ("d"cs | &X !Y)? @indent(c) @samecol c
    c := ~X Y* e+
    e := Z
    X := /[a\/b]+\d/ @refine("M", "r", W)
    Y := [^\]a-z[:alpha:]-] . "\x41\u{1F600}\-"
    Z := X{3} | X{1,} | X{1,2}
    @keywords Y { "if" -> IF, "do" -> DO }
    """

    assert reader_accepts?(source)
    assert grammar_accepts?(grammar, source)
  end
end
