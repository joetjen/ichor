defmodule Grammar.TokensTest do
  use ExUnit.Case, async: true
  doctest Grammar.Tokens

  alias Grammar.Tokens

  describe "list/1" do
    test "orders entries per token_order and classifies declared/anonymous/predefined" do
      {:ok, grammar} = Aether.Parser.parse(Support.ExampleGrammars.all()["4.1 calculator"])

      entries = Tokens.list(grammar)
      by_name = Map.new(entries, &{&1.name, &1})

      assert by_name[:NUMBER].kind == :declared
      assert by_name[:SPACE].kind == :predefined
      assert by_name[:DIGIT].kind == :predefined
      assert by_name[:ALPHA].kind == :predefined

      anon_names = for %{kind: :anonymous, name: name} <- entries, do: name
      anon_patterns = for %{name: name} <- entries, name in anon_names, do: by_name[name].pattern
      expected = for lit <- ["+", "-", "*", "/", "(", ")"], do: inspect(lit)
      assert Enum.sort(anon_patterns) == Enum.sort(expected)

      assert Enum.map(entries, & &1.name) == grammar.token_order
    end

    test "an overridden predefined token keeps its declaration position, not the tail" do
      {:ok, grammar} = Aether.Parser.parse(Support.ExampleGrammars.all()["4.5 sql"])

      names = grammar.token_order
      space_index = Enum.find_index(names, &(&1 == :SPACE))
      digit_index = Enum.find_index(names, &(&1 == :DIGIT))

      # SQL declares SPACE explicitly (overriding the predefined default) right
      # before the end of its own token block; DIGIT is never mentioned, so it
      # only appears via the non-overridden-predefined tail append.
      assert space_index < digit_index
      assert Enum.find(Tokens.list(grammar), &(&1.name == :SPACE)).kind == :predefined
    end
  end

  describe "describe/1" do
    test "renders repetition bounds" do
      digit = Grammar.IR.char_class([{?0, ?9}])

      assert Tokens.describe(Grammar.IR.rep(digit, 2, 2)) == "[0-9]{2}"
      assert Tokens.describe(Grammar.IR.rep(digit, 1, :infinity)) == "[0-9]{1,}"
      assert Tokens.describe(Grammar.IR.rep(digit, 1, 3)) == "[0-9]{1,3}"
    end

    test "parenthesizes a lower-precedence child but not a higher-precedence one" do
      choice = Grammar.IR.choice([Grammar.IR.literal("a"), Grammar.IR.literal("b")])
      digit = Grammar.IR.char_class([{?0, ?9}])

      assert Tokens.describe(Grammar.IR.star(choice)) == ~s[("a" | "b")*]
      assert Tokens.describe(Grammar.IR.star(digit)) == "[0-9]*"
    end

    test "renders negated char classes as the front-end's own !class . desugaring" do
      not_quote = Grammar.IR.not_pred(Grammar.IR.literal("\""))
      expr = Grammar.IR.seq([not_quote, Grammar.IR.any()])

      assert Tokens.describe(expr) == "!\"\\\"\" ."
    end

    test "escapes special characters inside a rendered char class" do
      ranges = [{?], ?]}, {?-, ?-}, {?^, ?^}]
      assert Tokens.describe(Grammar.IR.char_class(ranges)) == "[\\]\\-\\^]"
    end

    test "renders @indent/@samecol and named captures" do
      ref = Grammar.IR.rule_ref(:pair)
      assert Tokens.describe(Grammar.IR.indent(ref, :indent)) == "@indent(pair)"
      assert Tokens.describe(Grammar.IR.indent(ref, :samecol)) == "@samecol(pair)"
      assert Tokens.describe(Grammar.IR.capture(:op, Grammar.IR.literal("+"))) == "op:\"+\""
    end
  end
end
