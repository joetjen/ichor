defmodule LogQL.CrossFormatTest do
  use ExUnit.Case, async: true

  alias Support.CrossFormat

  @valid [
    ~S({app="ichor"} |= "error" | logfmt),
    ~S({app="ichor"}),
    ~S({app=~"ic.*"}),
    ~S({app="other", env="prod"}),
    ~S({app="missing"}),
    ~S({app="ichor"} != "error"),
    ~S({app="ichor"} |~ "err.*"),
    ~S({app="ichor"} !~ "err.*"),
    ~S({app="ichor"} |= "error" | line_format "<redacted>"),
    ~S({app="ichor"} | json)
  ]

  defp assert_recognizer_parity(grammar) do
    for input <- @valid do
      assert CrossFormat.accepts?(grammar, input), "expected #{inspect(input)} to be accepted"
    end
  end

  describe "ABNF" do
    test "recognizes the same LogQL syntax as native Aether's own logql grammar" do
      {:ok, ruleset} =
        "test/logql/logql.abnf" |> CrossFormat.read_abnf!() |> Ichor.ABNF.run()

      tokens = [
        :"line-format",
        :logfmt,
        :json,
        :"alpha-char",
        :"digit-char",
        :ident,
        :dquote,
        :"str-char",
        :string,
        :wschar
      ]

      grammar = ruleset |> CrossFormat.assemble(:query, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end

  describe "ISO EBNF" do
    test "recognizes the same LogQL syntax" do
      {:ok, ruleset} = "test/logql/logql.ebnf" |> File.read!() |> Ichor.EBNF.ISO.run()

      tokens = [
        :"line format",
        :logfmt,
        :json,
        :"alpha char",
        :"digit char",
        :ident,
        :"str char",
        :string
      ]

      grammar = ruleset |> CrossFormat.assemble(:query, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end

  describe "PEG" do
    test "recognizes the same LogQL syntax" do
      {:ok, ruleset} = "test/logql/logql.peg" |> File.read!() |> Ichor.PEG.run()

      tokens = [
        :line_format,
        :logfmt,
        :json,
        :alpha_char,
        :digit_char,
        :ident,
        :str_char,
        :string
      ]

      grammar = ruleset |> CrossFormat.assemble(:query, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end
end
