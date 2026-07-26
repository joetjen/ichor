defmodule Regex.CrossFormatTest do
  use ExUnit.Case, async: true

  alias Support.CrossFormat

  @valid [
    "\\d+(\\.\\d+)?",
    "\\d",
    "\\D",
    "a",
    "a|b|c",
    "a*",
    "a+",
    "a?",
    "a{3}",
    "a{3,}",
    "a{3,7}",
    "(ab)",
    "(?=a)",
    "(?!a)",
    "[a-z]",
    "[^a-z]",
    "[a-z0]",
    "."
  ]

  @invalid [
    "a**",
    "(a",
    "a)",
    "[a-z",
    "*a",
    "+a",
    "?a",
    "a{",
    "a{,}",
    "a,b"
  ]

  defp assert_recognizer_parity(grammar) do
    for input <- @valid do
      assert CrossFormat.accepts?(grammar, input), "expected #{inspect(input)} to be accepted"
    end

    for input <- @invalid do
      refute CrossFormat.accepts?(grammar, input), "expected #{inspect(input)} to be rejected"
    end
  end

  describe "ABNF" do
    test "recognizes the same regex pattern syntax as native Aether's own regex grammar" do
      {:ok, ruleset} = "test/regex/regex.abnf" |> CrossFormat.read_abnf!() |> Ichor.ABNF.run()

      tokens = [
        :"lookahead-pos",
        :"lookahead-neg",
        :"shorthand-class",
        :"escaped-char",
        :"literal-char"
      ]

      grammar = ruleset |> CrossFormat.assemble(:pattern, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end

  describe "ISO EBNF" do
    test "recognizes the same regex pattern syntax" do
      {:ok, ruleset} = "test/regex/regex.ebnf" |> File.read!() |> Ichor.EBNF.ISO.run()

      tokens = [
        :"lookahead pos",
        :"lookahead neg",
        :"shorthand class",
        :"escaped char",
        :"literal char"
      ]

      grammar = ruleset |> CrossFormat.assemble(:pattern, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end

  describe "PEG" do
    test "recognizes the same regex pattern syntax" do
      {:ok, ruleset} = "test/regex/regex.peg" |> File.read!() |> Ichor.PEG.run()

      tokens = [
        :lookahead_pos,
        :lookahead_neg,
        :shorthand_class,
        :escaped_char,
        :literal_char
      ]

      grammar = ruleset |> CrossFormat.assemble(:pattern, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end
end
