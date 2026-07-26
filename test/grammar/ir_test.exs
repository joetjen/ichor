defmodule Grammar.IRTest do
  use ExUnit.Case, async: true
  doctest Grammar.IR

  alias Grammar.IR

  test "every node struct defaults meta to an empty Grammar.IR.Meta" do
    assert IR.literal("x").meta == %IR.Meta{}
    assert IR.any().meta == %IR.Meta{}
  end

  test "meta carries source_span and, for imported grammars, source_format" do
    meta = %IR.Meta{source_span: {3, 5, 2}, source_format: :abnf}

    assert IR.literal("x", meta).meta == meta
  end

  test "seq and choice hold an ordered list of sub-expressions" do
    a = IR.literal("a")
    b = IR.literal("b")

    assert IR.seq([a, b]).exprs == [a, b]
    assert IR.choice([a, b]).exprs == [a, b]
  end

  test "rep normalizes {n} and {n,} shapes via explicit min/max" do
    exact = IR.rep(IR.any(), 3, 3)
    assert exact.min == 3 and exact.max == 3

    unbounded = IR.rep(IR.any(), 1, :infinity)
    assert unbounded.max == :infinity
  end

  test "indent only accepts :indent or :samecol" do
    assert %IR.Indent{kind: :indent} = IR.indent(IR.rule_ref(:pair), :indent)
    assert %IR.Indent{kind: :samecol} = IR.indent(IR.rule_ref(:pair), :samecol)

    assert_raise FunctionClauseError, fn ->
      IR.indent(IR.rule_ref(:pair), :nonsense)
    end
  end

  test "capture pairs a name with the expression it captures" do
    capture = IR.capture(:op, IR.literal("+"))
    assert capture.name == :op
    assert capture.expr == IR.literal("+")
  end

  test "char_class stores inclusive codepoint ranges" do
    assert IR.char_class([{?0, ?9}]).ranges == [{48, 57}]
  end
end
