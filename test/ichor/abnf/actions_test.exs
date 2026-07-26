defmodule Ichor.ABNF.ActionsTest do
  use ExUnit.Case, async: true
  doctest Ichor.ABNF

  alias Grammar.IR
  alias Support.IRStrip

  defp run(source), do: Ichor.ABNF.run(source)

  defp rule(source, name) do
    {:ok, ruleset} = run(source)
    Map.fetch!(ruleset, name)
  end

  describe "the ABNF worked example" do
    test "1*3DIGIT and a four-way concatenation" do
      source = """
      ip4-octet = 1*3DIGIT\r
      ip4-address = ip4-octet "." ip4-octet "." ip4-octet "." ip4-octet\r
      """

      assert {:ok, ruleset} = run(source)

      assert IRStrip.strip(ruleset[:"ip4-octet"]) ==
               IRStrip.strip(IR.rep(IR.rule_ref(:digit), 1, 3))

      assert IRStrip.strip(ruleset[:"ip4-address"]) ==
               IRStrip.strip(
                 IR.seq([
                   IR.rule_ref(:"ip4-octet"),
                   IR.literal("."),
                   IR.rule_ref(:"ip4-octet"),
                   IR.literal("."),
                   IR.rule_ref(:"ip4-octet"),
                   IR.literal("."),
                   IR.rule_ref(:"ip4-octet")
                 ])
               )
    end
  end

  describe "char-val (RFC 5234 section 2.3 / RFC 7405)" do
    test "plain quoted text is case-insensitive by RFC 5234's own default" do
      ir = rule("x = \"ab\"\r\n", :x)

      assert IRStrip.strip(ir) ==
               IRStrip.strip(
                 IR.seq([
                   IR.char_class([{?a, ?a}, {?A, ?A}]),
                   IR.char_class([{?b, ?b}, {?B, ?B}])
                 ])
               )
    end

    test "%s makes it case-sensitive (RFC 7405)" do
      assert IRStrip.strip(rule("x = %s\"ab\"\r\n", :x)) == IRStrip.strip(IR.literal("ab"))
    end

    test "%i is explicitly case-insensitive, same as the default" do
      ir = rule("x = %i\"ab\"\r\n", :x)

      assert IRStrip.strip(ir) ==
               IRStrip.strip(
                 IR.seq([
                   IR.char_class([{?a, ?a}, {?A, ?A}]),
                   IR.char_class([{?b, ?b}, {?B, ?B}])
                 ])
               )
    end

    test "the empty string matches epsilon" do
      assert IRStrip.strip(rule("x = \"\"\r\n", :x)) == IRStrip.strip(IR.literal(""))
    end

    test "a single character isn't wrapped in a Seq" do
      assert IRStrip.strip(rule("x = %s\"a\"\r\n", :x)) == IRStrip.strip(IR.literal("a"))
    end
  end

  describe "num-val (RFC 5234 section 2.3)" do
    test "a single hex character value" do
      assert IRStrip.strip(rule("x = %x41\r\n", :x)) == IRStrip.strip(IR.literal("A"))
    end

    test "a single decimal character value" do
      assert IRStrip.strip(rule("x = %d65\r\n", :x)) == IRStrip.strip(IR.literal("A"))
    end

    test "a single binary character value" do
      assert IRStrip.strip(rule("x = %b1000001\r\n", :x)) == IRStrip.strip(IR.literal("A"))
    end

    test "dot-concatenation builds a multi-character literal" do
      assert IRStrip.strip(rule("x = %x0D.0A\r\n", :x)) == IRStrip.strip(IR.literal("\r\n"))
    end

    test "a dash range builds a char class" do
      assert IRStrip.strip(rule("x = %x30-39\r\n", :x)) ==
               IRStrip.strip(IR.char_class([{?0, ?9}]))
    end
  end

  describe "prose-val (RFC 5234 section 3.6)" do
    test "has no executable meaning, so it's a real error, not silently accepted" do
      assert {:error, %Ichor.Error{message: message}} = run("x = <anything>\r\n")
      assert message =~ "prose-val"
    end
  end

  describe "repetition (RFC 5234 section 3.7)" do
    test "bare, no repeat prefix at all: the element passes through unwrapped" do
      assert IRStrip.strip(rule("x = DIGIT\r\n", :x)) == IRStrip.strip(IR.rule_ref(:digit))
    end

    test "* alone: zero or more" do
      assert IRStrip.strip(rule("x = *DIGIT\r\n", :x)) ==
               IRStrip.strip(IR.star(IR.rule_ref(:digit)))
    end

    test "1* : one or more" do
      assert IRStrip.strip(rule("x = 1*DIGIT\r\n", :x)) ==
               IRStrip.strip(IR.plus(IR.rule_ref(:digit)))
    end

    test "*n : zero to n" do
      assert IRStrip.strip(rule("x = *5DIGIT\r\n", :x)) ==
               IRStrip.strip(IR.rep(IR.rule_ref(:digit), 0, 5))
    end

    test "n* : n or more" do
      assert IRStrip.strip(rule("x = 2*DIGIT\r\n", :x)) ==
               IRStrip.strip(IR.rep(IR.rule_ref(:digit), 2, :infinity))
    end

    test "n*m : bounded" do
      assert IRStrip.strip(rule("x = 1*3DIGIT\r\n", :x)) ==
               IRStrip.strip(IR.rep(IR.rule_ref(:digit), 1, 3))
    end

    test "nDIGIT (exact count, multi-digit n)" do
      assert IRStrip.strip(rule("x = 12DIGIT\r\n", :x)) ==
               IRStrip.strip(IR.rep(IR.rule_ref(:digit), 12, 12))
    end
  end

  describe "groups and options" do
    test "a group is just its inner alternation" do
      assert IRStrip.strip(rule("x = (a / b)\r\n", :x)) ==
               IRStrip.strip(IR.choice([IR.rule_ref(:a), IR.rule_ref(:b)]))
    end

    test "an option wraps in Opt" do
      assert IRStrip.strip(rule("x = [a]\r\n", :x)) == IRStrip.strip(IR.opt(IR.rule_ref(:a)))
    end
  end

  describe "alternation / concatenation" do
    test "a single alternative isn't wrapped in Choice" do
      assert IRStrip.strip(rule("x = a\r\n", :x)) == IRStrip.strip(IR.rule_ref(:a))
    end

    test "multiple alternatives become a Choice, in source order" do
      assert IRStrip.strip(rule("x = a / b / c\r\n", :x)) ==
               IRStrip.strip(IR.choice([IR.rule_ref(:a), IR.rule_ref(:b), IR.rule_ref(:c)]))
    end

    test "a single element concatenation isn't wrapped in Seq" do
      assert IRStrip.strip(rule("x = a\r\n", :x)) == IRStrip.strip(IR.rule_ref(:a))
    end

    test "multiple elements become a Seq, in source order" do
      assert IRStrip.strip(rule("x = a b c\r\n", :x)) ==
               IRStrip.strip(IR.seq([IR.rule_ref(:a), IR.rule_ref(:b), IR.rule_ref(:c)]))
    end
  end

  describe "rule names (case-insensitive per RFC 5234)" do
    test "a rulename_ref resolves independent of case" do
      assert IRStrip.strip(rule("x = Ip4-Octet\r\n", :x)) ==
               IRStrip.strip(IR.rule_ref(:"ip4-octet"))
    end

    test "the rule's own name is likewise downcased" do
      {:ok, ruleset} = run("Ip4-Octet = DIGIT\r\n")
      assert Map.has_key?(ruleset, :"ip4-octet")
    end
  end

  describe "\"=/\" incremental alternatives (RFC 7405 section 2.3 / RFC 5234 section 3.3)" do
    test "extends an already-\"=\"-defined rule's own alternatives, in order" do
      source = """
      x = a\r
      x =/ b\r
      x =/ c\r
      """

      assert IRStrip.strip(rule(source, :x)) ==
               IRStrip.strip(IR.choice([IR.rule_ref(:a), IR.rule_ref(:b), IR.rule_ref(:c)]))
    end

    test "extending a rule whose own single alternative isn't already a Choice" do
      source = """
      x = a\r
      x =/ b\r
      """

      assert IRStrip.strip(rule(source, :x)) ==
               IRStrip.strip(IR.choice([IR.rule_ref(:a), IR.rule_ref(:b)]))
    end

    test "redefining a rule with a second plain \"=\" is a real error" do
      source = """
      x = a\r
      x = b\r
      """

      assert {:error, %Ichor.Error{message: message}} = run(source)
      assert message =~ "redefined"
    end

    test "using \"=/\" before the rule was ever \"=\"-defined is a real error" do
      assert {:error, %Ichor.Error{message: message}} = run("x =/ a\r\n")
      assert message =~ "before being defined"
    end
  end

  describe "comments and blank lines" do
    # A comment shares its own line (`blank_line := WSP* COMMENT? CRLF`)
    # -- a comment trailing a rule definition on the *same* line as its
    # `elements` isn't supported, since `rule` itself requires a bare
    # `CRLF` right after `elements`, not RFC 5234's own `c-nl = comment /
    # CRLF`. A narrow, deliberately accepted gap (same spirit as
    # `Regex.Actions`'s own moduledoc).
    test "a leading comment line and a blank line don't disturb the surrounding rules" do
      source = """
      ; a leading comment\r
      x = a\r
      \r
      ; another comment\r
      y = b\r
      """

      assert {:ok, ruleset} = run(source)
      assert IRStrip.strip(ruleset[:x]) == IRStrip.strip(IR.rule_ref(:a))
      assert IRStrip.strip(ruleset[:y]) == IRStrip.strip(IR.rule_ref(:b))
    end
  end

  describe "parse/1 and tokenize/1 (bare recognizer, generated by use Ichor)" do
    test "parse/1 matches with no Ichor.ABNF.Actions involved" do
      assert {:ok, _pos, _raw_captures} = Ichor.ABNF.parse("x = a\r\n")
    end

    test "tokenize/1 exposes the raw token stream" do
      assert {:ok, tokens} = Ichor.ABNF.tokenize("x = a\r\n")
      assert Enum.map(tokens, & &1.name) == [:RULENAME, :WSP, :DEFINED_AS, :WSP, :RULENAME, :CRLF]
    end
  end
end
