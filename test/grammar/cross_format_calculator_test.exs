defmodule Grammar.CrossFormatCalculatorTest do
  use ExUnit.Case, async: true

  alias Grammar.IR
  alias Support.{CrossFormat, ExampleGrammars, IRStrip}

  # Small enough to keep inline (like calculator's own native Aether
  # source in Support.ExampleGrammars) -- every other cross-format
  # fixture lives as a real file alongside this test module instead.
  @abnf ~S"""
  digit-char = %x30-39
  sp         = %x20 / %x09
  number     = 1*digit-char ["." 1*digit-char]
  expr       = term *(*sp addop *sp term)
  addop      = "+" / "-"
  term       = factor *(*sp mulop *sp factor)
  mulop      = "*" / "/"
  factor     = number / ("(" *sp expr *sp ")")
  """

  @ebnf ~S"""
  digit char = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;
  sp = " " ;
  number = digit char, { digit char }, [ ".", digit char, { digit char } ] ;
  expr = term, { { sp }, addop, { sp }, term } ;
  addop = "+" | "-" ;
  term = factor, { { sp }, mulop, { sp }, factor } ;
  mulop = "*" | "/" ;
  factor = number | ( "(", { sp }, expr, { sp }, ")" ) ;
  """

  @peg ~S"""
  number <- [0-9]+ ("." [0-9]+)?
  sp     <- " "
  expr   <- term (sp* addop sp* term)*
  addop  <- "+" / "-"
  term   <- factor (sp* mulop sp* factor)*
  mulop  <- "*" / "/"
  factor <- number / ("(" sp* expr sp* ")")
  """

  @valid [
    "2 + 3 * 4",
    "2",
    "(2 + 3) * 4",
    "1 + 2 + 3 + 4 + 5",
    "3.5 * 2",
    "10 / 2 - 1",
    "((1 + 2) * (3 + 4))",
    "100"
  ]

  @invalid ["2 + ", "not a number"]

  defp native_grammar do
    {:ok, grammar} = Aether.Parser.parse(ExampleGrammars.all()["4.1 calculator"])
    grammar
  end

  defp assert_recognizer_parity(grammar) do
    for input <- @valid do
      assert CrossFormat.accepts?(grammar, input), "expected #{inspect(input)} to be accepted"
    end

    for input <- @invalid do
      refute CrossFormat.accepts?(grammar, input), "expected #{inspect(input)} to be rejected"
    end
  end

  describe "ABNF" do
    setup do
      {:ok, ruleset} = @abnf |> CrossFormat.read_abnf_source!() |> Ichor.ABNF.run()

      grammar =
        ruleset
        |> CrossFormat.assemble(:expr, [:"digit-char", :sp, :addop, :mulop])
        |> CrossFormat.analyze!()

      {:ok, ruleset: ruleset, grammar: grammar}
    end

    test "recognizes exactly the same language as native calculator", %{grammar: grammar} do
      assert_recognizer_parity(grammar)
    end

    test "number is structurally identical to native NUMBER, once the digit primitive's own (deliberately different) name is accounted for",
         %{ruleset: ruleset} do
      renamed = CrossFormat.rename_refs(ruleset[:number], %{"digit-char": :DIGIT})
      assert IRStrip.strip(renamed) == IRStrip.strip(native_grammar().tokens[:NUMBER])
    end
  end

  describe "ISO EBNF" do
    setup do
      {:ok, ruleset} = Ichor.EBNF.ISO.run(@ebnf)

      grammar =
        ruleset
        |> CrossFormat.assemble(:expr, [:"digit char", :sp, :addop, :mulop])
        |> CrossFormat.analyze!()

      {:ok, ruleset: ruleset, grammar: grammar}
    end

    test "recognizes exactly the same language as native calculator", %{grammar: grammar} do
      assert_recognizer_parity(grammar)
    end

    test "number is the correct ISO EBNF idiom for native NUMBER's Plus (ISO EBNF has no native one-or-more operator, only { } for zero-or-more)",
         %{ruleset: ruleset} do
      renamed = CrossFormat.rename_refs(ruleset[:number], %{"digit char": :DIGIT})
      digit = IR.rule_ref(:DIGIT)

      # `single_definition := term (COMMA term)*` builds one flat Seq
      # across every comma-separated term -- ISO EBNF's own comma-sequence
      # has no grouping unless parens/brackets ask for it, so this is
      # correctly *not* nested the way `expr := factor, { factor }`'s
      # "one-or-more" sub-expression might otherwise suggest.
      expected =
        IR.seq([digit, IR.star(digit), IR.opt(IR.seq([IR.literal("."), digit, IR.star(digit)]))])

      assert IRStrip.strip(renamed) == IRStrip.strip(expected)
    end
  end

  describe "PEG" do
    setup do
      {:ok, ruleset} = Ichor.PEG.run(@peg)

      grammar =
        ruleset
        |> CrossFormat.assemble(:expr, [:sp, :addop, :mulop])
        |> CrossFormat.analyze!()

      {:ok, ruleset: ruleset, grammar: grammar}
    end

    test "recognizes exactly the same language as native calculator", %{grammar: grammar} do
      assert_recognizer_parity(grammar)
    end

    test "number is structurally identical to native NUMBER (PEG's own [0-9]+ is inlined, no separate digit rule to rename)",
         %{ruleset: ruleset} do
      expected =
        IR.seq([
          IR.plus(IR.char_class([{?0, ?9}])),
          IR.opt(IR.seq([IR.literal("."), IR.plus(IR.char_class([{?0, ?9}]))]))
        ])

      assert IRStrip.strip(ruleset[:number]) == IRStrip.strip(expected)
    end
  end
end
