defmodule Lisp.BNFCrossFormatTest do
  @moduledoc """
  A classic-BNF (`Ichor.BNF`) rendering of the same LISP reader syntax
  `test/lisp/cross_format_test.exs` already proves for ABNF/ISO EBNF/PEG
  -- deliberately a *reduced* subset, not a fourth copy of the full
  grammar: classic BNF (as `Ichor.BNF` implements it, matching real BNF
  as actually written) has no repetition operator, no optional, and no
  character-class shorthand at all -- `sequence := element+` in
  `priv/grammar/bnf.aether` itself requires at least one element, so
  there's no way to write an empty right-hand side/epsilon production.
  Every repeated construct here is BNF's own only technique for it,
  right-recursion (`<number> ::= <digit-char> | <digit-char> <number>`,
  the same shape `test/ichor/bnf/actions_test.exs`'s own worked example
  uses) -- and since "zero or more" has no BNF equivalent at all,
  `<form-seq>`/lists require exactly one space between forms and at
  least one form (no empty list literal `()`, no extra whitespace).
  Vectors, maps, and the quasiquote/unquote/meta reader-sugar forms are
  dropped entirely, not worked around -- an honest scope cut, not a bug.
  """

  use ExUnit.Case, async: true

  alias Support.CrossFormat

  @valid [
    "hello",
    "42",
    "-3",
    "\"hi there\"",
    "(a b c)",
    "(a (b c) d)",
    "'x",
    "(quote (a b c))"
  ]

  @tokens [
    :"alpha-char",
    :"digit-char",
    :"symbol-start",
    :"symbol-char",
    :"symbol-tail",
    :symbol,
    :number,
    :"str-char",
    :"string-body",
    :string
  ]

  test "recognizes a reduced subset of the same LISP reader syntax the other three formats prove" do
    {:ok, ruleset} = "test/lisp/lisp.bnf" |> File.read!() |> Ichor.BNF.run()
    grammar = ruleset |> CrossFormat.assemble(:form, @tokens) |> CrossFormat.analyze!()

    for input <- @valid do
      assert CrossFormat.accepts?(grammar, input), "expected #{inspect(input)} to be accepted"
    end
  end

  test "symbol and number must each be self-contained tokens, the same lesson the ABNF version already found" do
    {:ok, ruleset} = "test/lisp/lisp.bnf" |> File.read!() |> Ichor.BNF.run()
    grammar = ruleset |> CrossFormat.assemble(:form, @tokens) |> CrossFormat.analyze!()

    assert CrossFormat.accepts?(grammar, "abc123")
    assert CrossFormat.accepts?(grammar, "1")
  end

  test "an empty list is rejected -- the documented BNF-can't-express-epsilon gap" do
    {:ok, ruleset} = "test/lisp/lisp.bnf" |> File.read!() |> Ichor.BNF.run()
    grammar = ruleset |> CrossFormat.assemble(:form, @tokens) |> CrossFormat.analyze!()

    refute CrossFormat.accepts?(grammar, "()")
  end
end
