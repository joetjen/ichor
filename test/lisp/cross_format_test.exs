defmodule Lisp.CrossFormatTest do
  use ExUnit.Case, async: true

  alias Support.CrossFormat

  @valid [
    "(quote unbound-thing)",
    "'yes",
    "(quote (a (b c) 1))",
    "(quote ())",
    "((fn [] 42))",
    "((fn [x] x) 5)",
    "(def x 1)",
    "[1 2 3]",
    "{:a 1}",
    "(let [x 5] (* x x))",
    "-3.5",
    "(defmacro my-if (test then else) (list 'cond test then 1 else))",
    ~S{(quote "hello world!")}
  ]

  defp assert_recognizer_parity(grammar) do
    for input <- @valid do
      assert CrossFormat.accepts?(grammar, input), "expected #{inspect(input)} to be accepted"
    end
  end

  describe "ABNF" do
    test "recognizes the same LISP reader syntax as native Aether's own lisp grammar" do
      {:ok, ruleset} =
        "test/lisp/lisp.abnf" |> CrossFormat.read_abnf!() |> Ichor.ABNF.run()

      tokens = [
        :"alpha-char",
        :"digit-char",
        :dquote,
        :sp,
        :"symbol-start",
        :"str-char",
        :symbol,
        :keyword,
        :string,
        :number
      ]

      grammar = ruleset |> CrossFormat.assemble(:form, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end

  describe "ISO EBNF" do
    test "recognizes the same LISP reader syntax" do
      {:ok, ruleset} = "test/lisp/lisp.ebnf" |> File.read!() |> Ichor.EBNF.ISO.run()

      tokens = [
        :"alpha char",
        :"digit char",
        :sp,
        :"symbol start",
        :"str char",
        :symbol,
        :keyword,
        :string,
        :number
      ]

      grammar = ruleset |> CrossFormat.assemble(:form, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end

  describe "PEG" do
    test "recognizes the same LISP reader syntax" do
      {:ok, ruleset} = "test/lisp/lisp.peg" |> File.read!() |> Ichor.PEG.run()

      tokens = [
        :alpha_char,
        :digit_char,
        :sp,
        :symbol_start,
        :str_char,
        :symbol,
        :keyword,
        :string,
        :number
      ]

      grammar = ruleset |> CrossFormat.assemble(:form, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end

  describe "a lesson this LISP fixture found (see Support.CrossFormat's own moduledoc)" do
    test "symbol/keyword/string/number must each be one self-contained token, not a rule built from shared helper tokens" do
      # Forcing every ABNF/EBNF/PEG grammar through Aether's own mandatory
      # two-stage lexer+parser (Grammar.VM) means maximal munch applies
      # globally, at every position, regardless of which rule is "currently"
      # being parsed -- exactly like native Aether's own SYMBOL/NUMBER
      # tokens. A helper like `digit-char`, independently referenced by
      # *both* `symbol` and `number`, ties with whichever of them also
      # tries to match a bare single digit, and declaration order alone
      # decides -- permanently starving whichever one loses, for every
      # occurrence of that character in the file, not just the "wrong"
      # one. Making symbol/number self-contained tokens (matching how
      # native Aether's own lisp.aether already categorizes them) means
      # they compete against each other correctly, by length, exactly
      # the way native SYMBOL/NUMBER already do.
      {:ok, ruleset} =
        "test/lisp/lisp.abnf" |> CrossFormat.read_abnf!() |> Ichor.ABNF.run()

      tokens = [
        :"alpha-char",
        :"digit-char",
        :dquote,
        :sp,
        :"symbol-start",
        :"str-char",
        :symbol,
        :keyword,
        :string,
        :number
      ]

      grammar = ruleset |> CrossFormat.assemble(:form, tokens) |> CrossFormat.analyze!()

      # A symbol with an embedded digit, and a bare single-digit number,
      # both need to resolve correctly -- the exact case that broke when
      # `digit-char` was independently referenced by both `symbol` and
      # `number` as separate multi-char rules instead.
      assert CrossFormat.accepts?(grammar, "abc123")
      assert CrossFormat.accepts?(grammar, "1")
    end
  end
end
