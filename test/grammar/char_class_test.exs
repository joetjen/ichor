defmodule Grammar.CharClassTest do
  @moduledoc """
  A character class matches the union of its ranges, whatever their
  order, overlaps or size, by both backends. A generated parser prepares
  each class once (`Tokenizer.char_class/1`), so a class with hundreds
  of ranges costs a bit test or a binary search per character, not a
  scan of every range.
  """

  use ExUnit.Case, async: true

  @grammar ~S"""
  @grammar "classes"
  @root words
  @skip WS
  WS   := [ ]+
  WORD := [x-zа-яa-ca-e0-9]+
  words := WORD+
  """

  defp grammar(source) do
    {:ok, grammar} = Aether.Parser.parse(source, nil)
    grammar
  end

  defp run(:interpreted, source, input) do
    {:ok, analysed} = Grammar.Analysis.run(grammar(source))
    Grammar.VM.run(analysed, input, Support.NoActions)
  end

  defp run(:compiled, source, input) do
    name = Module.concat(__MODULE__, "P#{System.unique_integer([:positive])}")
    Module.create(name, Ichor.generate_from_grammar(grammar(source), Support.NoActions), __ENV__)
    name.run(input)
  end

  for backend <- [:interpreted, :compiled] do
    describe "#{backend}" do
      test "a character in any of the ranges matches, overlapping ones included" do
        assert {:ok, _} = run(unquote(backend), @grammar, "abe xyz 09 жук")
      end

      test "a character in none of them does not" do
        assert {:error, _} = run(unquote(backend), @grammar, "abf")
        assert {:error, _} = run(unquote(backend), @grammar, "w")
        assert {:error, _} = run(unquote(backend), @grammar, "ё")
      end
    end
  end

  test "a generated parser asks the prepared class, not the list of ranges" do
    source = Macro.to_string(Ichor.generate_from_grammar(grammar(@grammar), Support.NoActions))

    assert source =~ "Tokenizer.in_class?("
    refute source =~ "Tokenizer.in_ranges?("
  end
end
