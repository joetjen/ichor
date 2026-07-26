defmodule SQL.CrossFormatTest do
  use ExUnit.Case, async: true

  alias Support.CrossFormat

  # ABNF's own quoted char-vals are case-insensitive by default (RFC
  # 5234), matching native SQL's own `@case_insensitive`; ISO EBNF/PEG
  # stay case-sensitive here (a deliberate scope reduction, not
  # attempting to replicate `@case_insensitive` in formats with no such
  # pragma) -- every input below uses one consistent casing so it's
  # accepted by all three either way.
  @valid [
    "SELECT id, name FROM users WHERE id = 42",
    "SELECT * FROM users",
    "SELECT name FROM users",
    "SELECT * FROM users WHERE name = 'bob'",
    "SELECT * FROM users WHERE id != 1",
    "SELECT * FROM users WHERE id <= 1",
    "SELECT * FROM users WHERE id >= 42",
    "SELECT * FROM users WHERE id < 2",
    "SELECT * FROM users WHERE id > 2"
  ]

  defp assert_recognizer_parity(grammar) do
    for input <- @valid do
      assert CrossFormat.accepts?(grammar, input), "expected #{inspect(input)} to be accepted"
    end
  end

  describe "ABNF" do
    test "recognizes the same SQL syntax as native Aether's own sql grammar" do
      {:ok, ruleset} = "test/sql/sql.abnf" |> CrossFormat.read_abnf!() |> Ichor.ABNF.run()

      tokens = [
        :select,
        :from,
        :where,
        :"alpha-char",
        :"digit-char",
        :ident,
        :squote,
        :"str-char",
        :string,
        :number
      ]

      grammar = ruleset |> CrossFormat.assemble(:"select-stmt", tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end

  describe "ISO EBNF" do
    test "recognizes the same SQL syntax" do
      {:ok, ruleset} = "test/sql/sql.ebnf" |> File.read!() |> Ichor.EBNF.ISO.run()

      tokens = [
        :select,
        :from,
        :where,
        :"alpha char",
        :"digit char",
        :ident,
        :"str char",
        :string,
        :number
      ]

      grammar = ruleset |> CrossFormat.assemble(:"select stmt", tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end

  describe "PEG" do
    test "recognizes the same SQL syntax" do
      {:ok, ruleset} = "test/sql/sql.peg" |> File.read!() |> Ichor.PEG.run()

      tokens = [
        :select,
        :from,
        :where,
        :alpha_char,
        :digit_char,
        :ident,
        :str_char,
        :string,
        :number
      ]

      grammar = ruleset |> CrossFormat.assemble(:select_stmt, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end
end
