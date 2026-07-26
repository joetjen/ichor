defmodule Aether.LexerTest do
  use ExUnit.Case, async: true

  alias Aether.Lexer
  alias Aether.Token

  defp types(source) do
    {:ok, tokens} = Lexer.lex(source)
    Enum.map(tokens, & &1.type)
  end

  defp lex!(source) do
    {:ok, tokens} = Lexer.lex(source)
    tokens
  end

  test "pragmas" do
    assert types("@grammar @root @skip @noskip @case_insensitive @indent @samecol") ==
             [
               :at_grammar,
               :at_root,
               :at_skip,
               :at_noskip,
               :at_case_insensitive,
               :at_indent,
               :at_samecol,
               :eof
             ]
  end

  test "unknown pragma is a Ichor.Error at the right position" do
    assert {:error, error} = Lexer.lex("@bogus")
    assert error.stage == :lexer
    assert error.line == 1
    assert error.column == 1
    assert error.message =~ "unknown pragma"
  end

  test "punctuation" do
    assert types("| * + ? { } , & ! : ( ) ~ . :=") ==
             [
               :pipe,
               :star,
               :plus,
               :question,
               :lbrace,
               :rbrace,
               :comma,
               :amp,
               :bang,
               :colon,
               :lparen,
               :rparen,
               :tilde,
               :dot,
               :define,
               :eof
             ]
  end

  test "upper_ident vs lower_ident classification" do
    [t1, t2, t3, t4, eof] = lex!("SOME_TOKEN some_rule kebab-rule _LEADING_UNDERSCORE")
    assert t1.type == :upper_ident and t1.value == "SOME_TOKEN"
    assert t2.type == :lower_ident and t2.value == "some_rule"
    assert t3.type == :lower_ident and t3.value == "kebab-rule"
    assert t4.type == :upper_ident and t4.value == "_LEADING_UNDERSCORE"
    assert eof.type == :eof
  end

  test "mixed-case identifier is rejected" do
    assert {:error, error} = Lexer.lex("Foo_BAR")
    assert error.stage == :lexer
    assert error.message =~ "invalid identifier"
  end

  test "numbers" do
    [t, eof] = lex!("123")
    assert t.type == :number and t.value == 123
    assert eof.type == :eof
  end

  test "comments run to end of line and are dropped" do
    assert types("SOME ; this is a comment\nOTHER") == [:upper_ident, :upper_ident, :eof]
  end

  test "plain string literal" do
    [t, _eof] = lex!(~S("hello"))
    assert t.type == :string
    assert t.value == %{text: "hello", case: :default}
  end

  test "string literal suffixes -- i and cs" do
    [t1, _] = lex!(~S("select"i))
    assert t1.value == %{text: "select", case: :insensitive}

    [t2, _] = lex!(~S("select"cs))
    assert t2.value == %{text: "select", case: :sensitive}
  end

  test "string escapes" do
    [t, _] = lex!(~S("a\nb\tc\\d\"e\[f\]"))
    assert t.value.text == "a\nb\tc\\d\"e[f]"
  end

  test "\\x and \\u{...} escapes" do
    [t, _] = lex!(~S("\x41\u{1F600}"))
    assert t.value.text == "A\u{1F600}"
  end

  test "unterminated string literal is a Ichor.Error" do
    assert {:error, error} = Lexer.lex(~S("unterminated))
    assert error.message =~ "unterminated string"
  end

  test "invalid string suffix is rejected" do
    assert {:error, error} = Lexer.lex(~S("x"ignore))
    assert error.message =~ "invalid string suffix"
  end

  test "character class with ranges, escapes, and negation" do
    [t, _] = lex!("[a-z0-9_]")

    assert t.type == :char_class

    assert t.value == %{
             negate: false,
             items: [{:range, ?a, ?z}, {:range, ?0, ?9}, {:char, ?_}]
           }
  end

  test "negated character class" do
    [t, _] = lex!("[^a-z]")
    assert t.value.negate == true
    assert t.value.items == [{:range, ?a, ?z}]
  end

  test "character class with an escaped ] and a trailing literal dash" do
    [t, _] = lex!("[\\]a-]")
    assert t.value == %{negate: false, items: [{:char, ?]}, {:char, ?a}, {:char, ?-}]}
  end

  test "POSIX bracket classes" do
    [t, _] = lex!("[[:alpha:]_]")
    assert t.value == %{negate: false, items: [{:posix, :alpha}, {:char, ?_}]}
  end

  test "unknown POSIX class is a Ichor.Error" do
    assert {:error, error} = Lexer.lex("[[:bogus:]]")
    assert error.message =~ "unknown POSIX class"
  end

  test "unterminated character class is a Ichor.Error" do
    assert {:error, error} = Lexer.lex("[a-z")
    assert error.message =~ "unterminated character class"
  end

  test "regex literal captures raw pattern text between slashes" do
    [t, _] = lex!(~S{/\d+(\.\d+)?/})
    assert t.type == :regex
    assert t.value == "\\d+(\\.\\d+)?"
  end

  test "regex literal tolerates a slash inside a character class" do
    [t, _] = lex!("/[a/b]/")
    assert t.value == "[a/b]"
  end

  test "unterminated regex literal is a Ichor.Error" do
    assert {:error, error} = Lexer.lex("/abc")
    assert error.message =~ "unterminated regex literal"
  end

  test "the calculator grammar lexes end to end without error" do
    source = """
    @grammar "calculator"
    @root expr

    ; ---- tokens ----
    NUMBER := /\\d+(\\.\\d+)?/
    SPACE  := [ \\t\\n]+

    ; ---- rules ----
    expr   := term (op:("+" | "-") term)*
    term   := factor (op:("*" | "/") factor)*
    factor := NUMBER | "(" expr ")"
    """

    assert {:ok, tokens} = Lexer.lex(source)
    assert List.last(tokens).type == :eof
    refute Enum.any?(tokens, &(&1.type == :eof and &1 != List.last(tokens)))
  end

  test "every token carries a 1-based line and column" do
    [t1, t2, _eof] = lex!("foo\n  bar")
    assert %Token{line: 1, column: 1} = t1
    assert %Token{line: 2, column: 3} = t2
  end
end
