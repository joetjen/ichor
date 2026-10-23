defmodule Grammar.FirstCharsTest do
  @moduledoc """
  The characters a token's match can begin with, worked out when a
  parser is generated, so its tokenizer tries at each position only the
  tokens that can start with the next character. Wherever that cannot be
  told exactly, the answer is `:any` and the token is always tried: a
  start set may hold too much, never too little.
  """

  use ExUnit.Case, async: true

  doctest Grammar.FirstChars

  alias Grammar.FirstChars
  alias Grammar.IR

  defp first(tokens, name), do: FirstChars.of(tokens, name)

  test "a literal begins with its first character" do
    assert first(%{KW: IR.literal("let")}, :KW) == {:ranges, [{?l, ?l}]}
  end

  test "a character class begins with any of its ranges" do
    assert first(%{D: IR.char_class([{?0, ?9}])}, :D) == {:ranges, [{?0, ?9}]}
  end

  test "a choice begins with what any alternative begins with" do
    tokens = %{T: IR.choice([IR.literal("+"), IR.char_class([{?a, ?z}])])}
    assert first(tokens, :T) == {:ranges, [{?+, ?+}, {?a, ?z}]}
  end

  test "a sequence looks past the elements that can match nothing" do
    tokens = %{
      N: IR.seq([IR.opt(IR.literal("-")), IR.star(IR.literal(" ")), IR.char_class([{?0, ?9}])])
    }

    assert first(tokens, :N) == {:ranges, [{?\s, ?\s}, {?-, ?-}, {?0, ?9}]}
  end

  test "a token that can match nothing still begins only where it can match something" do
    assert first(%{S: IR.star(IR.literal("x"))}, :S) == {:ranges, [{?x, ?x}]}
  end

  test "an empty literal begins with nothing" do
    assert first(%{E: IR.literal("")}, :E) == {:ranges, []}
  end

  test "a reference to another token begins as that token does" do
    tokens = %{DIGIT: IR.char_class([{?0, ?9}]), INT: IR.plus(IR.rule_ref(:DIGIT))}
    assert first(tokens, :INT) == {:ranges, [{?0, ?9}]}
  end

  test "a token reaching itself again before any character is any" do
    tokens = %{A: IR.choice([IR.seq([IR.rule_ref(:A), IR.literal("a")]), IR.literal("b")])}
    assert first(tokens, :A) == :any
  end

  test "a lookahead adds nothing, and what follows it counts" do
    tokens = %{W: IR.seq([IR.and_pred(IR.literal("a")), IR.char_class([{?a, ?z}])])}
    assert first(tokens, :W) == {:ranges, [{?a, ?z}]}
  end

  test "any character, and anything not worked out, is any" do
    assert first(%{A: IR.any()}, :A) == :any
    assert first(%{N: IR.seq([IR.not_pred(IR.literal("*/")), IR.any()])}, :N) == :any
  end
end
