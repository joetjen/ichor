defmodule Aether.ParserTest do
  use ExUnit.Case, async: true

  alias Aether.Parser
  alias Grammar.IR

  defp ok!(source) do
    case Parser.parse(source) do
      {:ok, grammar} ->
        grammar

      {:error, error} ->
        flunk("expected #{inspect(source)} to parse, got:\n#{Ichor.Error.format(error)}")
    end
  end

  defp fails(source) do
    case Parser.parse(source) do
      {:error, error} -> error
      {:ok, _} -> flunk("expected #{inspect(source)} to fail to parse")
    end
  end

  # ---- the 9 worked example grammars parse cleanly ---------------------

  describe "worked example grammars parse without error" do
    test "4.1 calculator" do
      grammar =
        ok!(~S"""
        @grammar "calculator"
        @root expr

        NUMBER := /\d+(\.\d+)?/
        SPACE  := [ \t\n]+

        expr   := term (op:("+" | "-") term)*
        term   := factor (op:("*" | "/") factor)*
        factor := NUMBER | "(" expr ")"
        """)

      assert grammar.name == "calculator"
      assert grammar.root == :expr
    end

    test "4.2 lisp" do
      grammar =
        ok!(~S"""
        @grammar "lisp"
        @root form
        @skip TRIVIA

        LPAREN       := "("
        RPAREN       := ")"
        LBRACKET     := "["
        RBRACKET     := "]"
        LBRACE       := "{"
        RBRACE       := "}"
        QUOTE        := "'"
        BACKTICK     := "`"
        TILDE_AT     := "~@"
        TILDE        := "~"
        CARET        := "^"
        SYMBOL_START := [[:alpha:]_+\-*/<>=!?]
        SYMBOL_CHAR  := [[:alnum:]_+\-*/<>=!?]
        SYMBOL       := SYMBOL_START SYMBOL_CHAR*
        KEYWORD      := ":" SYMBOL
        STRING       := "\"" (!"\"" .)* "\""
        NUMBER       := "-"? DIGIT+ ("." DIGIT+)?
        COMMENT      := ";" (!"\n" .)* "\n"?
        SPACE        := [ \t\n,]+
        TRIVIA       := (SPACE | COMMENT)*

        form                  := list | vector | map | reader_macro | atom
        list                  := LPAREN form* RPAREN
        vector                := LBRACKET form* RBRACKET
        map                   := LBRACE (form form)* RBRACE
        reader_macro          := quote_sugar | quasiquote_sugar | unquote_splice_sugar | unquote_sugar | meta_sugar
        quote_sugar           := QUOTE form
        quasiquote_sugar      := BACKTICK form
        unquote_splice_sugar  := TILDE_AT form
        unquote_sugar         := TILDE form
        meta_sugar            := CARET meta:form target:form
        atom                  := SYMBOL | KEYWORD | STRING | NUMBER
        """)

      assert grammar.root == :form
      assert grammar.skip == :TRIVIA
    end

    test "4.3 yaml" do
      grammar =
        ok!(~S"""
        @grammar "yaml"
        @root document
        @skip INLINE_WS

        COLON      := ":"
        DASH       := "-"
        NEWLINE    := "\n"
        INLINE_WS  := [ \t]*
        KEY        := (!":" !"\n" .)+
        SCALAR     := (!"\n" .)+

        document     := mapping | sequence | scalar_doc
        mapping      := @indent( pair (NEWLINE @samecol pair)* )
        pair         := KEY COLON (inline_value | NEWLINE @indent(block_value))
        inline_value := SCALAR
        block_value  := mapping | sequence | scalar_doc
        sequence     := @indent( item (NEWLINE @samecol item)* )
        item         := DASH (mapping | scalar_doc)
        scalar_doc   := SCALAR
        """)

      assert grammar.root == :document
      assert %IR.Indent{kind: :indent} = grammar.rules[:mapping]
    end

    test "4.4 logql" do
      grammar =
        ok!(~S"""
        @grammar "logql"
        @root query

        LBRACE      := "{"
        RBRACE      := "}"
        COMMA       := ","
        PIPE        := "|"
        MATCH_OP    := "=~" | "!~" | "!=" | "="
        FILTER_OP   := "|=" | "!=" | "|~" | "!~"
        IDENT       := [[:alpha:]_][[:alnum:]_]*
        STRING      := "\"" (!"\"" .)* "\""
        LINE_FORMAT := "line_format"
        LOGFMT      := "logfmt"
        JSON        := "json"
        SPACE       := [ \t]*

        query             := stream_selector pipeline_stage*
        stream_selector   := LBRACE label_matcher (COMMA label_matcher)* RBRACE
        label_matcher     := IDENT MATCH_OP STRING
        pipeline_stage    := PIPE (filter_expr | line_format_stage | logfmt_stage | json_stage)
        filter_expr       := FILTER_OP STRING
        line_format_stage := LINE_FORMAT STRING
        logfmt_stage      := LOGFMT
        json_stage        := JSON
        """)

      assert grammar.root == :query
    end

    test "4.5 sql" do
      grammar =
        ok!(~S"""
        @grammar "sql"
        @root select_stmt
        @case_insensitive

        SELECT := "SELECT"
        FROM   := "FROM"
        WHERE  := "WHERE"
        STAR   := "*"
        COMMA  := ","
        EQ     := "="
        NEQ    := "!="
        LE     := "<="
        GE     := ">="
        LT     := "<"
        GT     := ">"
        IDENT  := [[:alpha:]_][[:alnum:]_]*
        STRING := /'[^']*'/
        NUMBER := /\d+/
        SPACE  := [ \t\n]+

        select_stmt   := SELECT column_list FROM table_ref where_clause?
        column_list   := column (COMMA column)*
        column        := STAR | IDENT
        table_ref     := IDENT
        where_clause  := WHERE condition
        condition     := IDENT comparison_op literal
        comparison_op := EQ | NEQ | LE | GE | LT | GT
        literal       := STRING | NUMBER
        """)

      assert grammar.case_insensitive
      # SELECT desugars per-character since @case_insensitive applies grammar-wide.
      assert %IR.Seq{exprs: [%IR.CharClass{} | _]} = grammar.tokens[:SELECT]
    end

    test "4.6 http" do
      grammar =
        ok!(~S"""
        @grammar "http"
        @root request
        @skip HWS

        METHOD       := "GET" | "POST" | "PUT" | "DELETE" | "HEAD" | "OPTIONS" | "PATCH"
        SP           := " "
        URI          := (!" " .)+
        HTTP_VERSION := "HTTP/" DIGIT "." DIGIT
        CRLF         := "\r\n"
        COLON        := ":"
        HEADER_NAME  := (!":" !"\r" !"\n" .)+
        HEADER_VALUE := (!"\r" !"\n" .)+
        HWS          := [ \t]*
        BODY_BYTE    := .

        request := request_line header* CRLF body?

        request_line := METHOD ~SP ~URI ~SP ~HTTP_VERSION ~CRLF

        header := HEADER_NAME COLON HEADER_VALUE CRLF
        body   := BODY_BYTE*
        """)

      assert grammar.root == :request
      assert grammar.skip == :HWS

      # every gap in request_line is tilde-suppressed -- no HWS* stars at all.
      request_line = grammar.rules[:request_line]
      assert %IR.Seq{exprs: exprs} = request_line
      refute Enum.any?(exprs, &match?(%IR.Star{expr: %IR.RuleRef{name: :HWS}}, &1))
    end

    test "4.7 regex (self-hosting)" do
      grammar =
        ok!(~S"""
        @grammar "regex"
        @root pattern
        @noskip

        LOOKAHEAD_POS   := "(?="
        LOOKAHEAD_NEG   := "(?!"
        LPAREN          := "("
        RPAREN          := ")"
        LBRACKET        := "["
        RBRACKET        := "]"
        CARET           := "^"
        DASH            := "-"
        STAR            := "*"
        PLUS            := "+"
        QUESTION        := "?"
        PIPE            := "|"
        LBRACE          := "{"
        RBRACE          := "}"
        COMMA           := ","
        DOT             := "."
        SHORTHAND_CLASS := "\\d" | "\\w" | "\\s" | "\\D" | "\\W" | "\\S"
        ESCAPED_CHAR    := "\\" [.\[\]\^\-*+?|(){}\\/dwsDWSnrt]
        CLASS_CHAR      := ESCAPED_CHAR | (!"]" .)
        LITERAL_CHAR    := !("(" | ")" | "[" | "]" | "^" | "*" | "+" | "?" | "|" | "{" | "}" | "\\" | ".") .

        pattern     := alternative (PIPE alternative)*
        alternative := term*
        term        := atom quantifier?
        quantifier  := STAR | PLUS | QUESTION | bound
        bound       := LBRACE min:(DIGIT+) (COMMA max:(DIGIT*))? RBRACE
        atom        := group | char_class | DOT | SHORTHAND_CLASS | ESCAPED_CHAR | LITERAL_CHAR
        group       := (LOOKAHEAD_POS | LOOKAHEAD_NEG | LPAREN) pattern RPAREN
        char_class  := LBRACKET CARET? class_item+ RBRACKET
        class_item  := range | CLASS_CHAR
        range       := from:CLASS_CHAR DASH to:CLASS_CHAR
        """)

      assert grammar.skip == nil
      assert grammar.root == :pattern
    end

    test "4.8 forth" do
      grammar =
        ok!(~S"""
        @grammar "forth"
        @root program

        COLON     := ":"
        SEMI      := ";"
        NUMBER    := /-?\d+/
        WORD_NAME := (!":" !";" !SPACE .)+

        program    := form*
        form       := definition | NUMBER | WORD_NAME
        definition := COLON WORD_NAME form* SEMI
        """)

      assert grammar.root == :program
      # relies on the implicit default SPACE inside WORD_NAME's negative lookahead
      assert Map.has_key?(grammar.tokens, :SPACE)
    end

    test "4.9 markdown" do
      grammar =
        ok!(~S"""
        @grammar "markdown"
        @root document
        @noskip

        HASH       := "#"
        DASH       := "-"
        STAR2      := "**"
        LBRACKET   := "["
        RBRACKET   := "]"
        LPAREN     := "("
        RPAREN     := ")"
        NEWLINE    := "\n"
        SP         := " "
        PLAIN_CHAR := !("*" | "[" | "\n") .
        URL_CHAR   := !")" .

        document  := block (NEWLINE+ block)*
        block     := heading | list | paragraph
        heading   := level:HASH+ SP inline
        list      := item (NEWLINE item)*
        item      := DASH SP inline
        paragraph := inline (NEWLINE inline)*
        inline    := (bold | link | plain)*
        bold      := STAR2 inline STAR2
        link      := LBRACKET inline RBRACKET LPAREN url:URL_CHAR* RPAREN
        plain     := PLAIN_CHAR+
        """)

      assert grammar.root == :document
    end
  end

  # ---- documented invalid cases raise the right Ichor.Error --------------

  describe "predefined-token override ordering" do
    test "overriding DIGIT after it has already been used is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        r := DIGIT
        DIGIT := [0-9]
        """)

      assert error.stage == :parser
      assert error.message =~ "cannot override DIGIT"
      assert error.message =~ "already used"
    end

    test "overriding a predefined token twice is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        DIGIT := [0-9]
        DIGIT := [0-9]
        r := DIGIT
        """)

      assert error.message =~ "DIGIT may only be declared once"
    end

    test "overriding DIGIT before use, then relying on the default elsewhere, is fine" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        DIGIT := [0-9٠-٩]
        r := DIGIT+
        """)

      assert %IR.CharClass{ranges: ranges} = grammar.tokens[:DIGIT]
      assert {0x0660, 0x0669} in ranges
    end

    test "ALNUM composes the current DIGIT/ALPHA defaults when not itself overridden" do
      grammar =
        ok!(~S"""
        @grammar "t"
        @root r
        r := ALNUM+
        """)

      assert %IR.Choice{exprs: [%IR.CharClass{}, %IR.CharClass{}]} = grammar.tokens[:ALNUM]
    end
  end

  describe "token/rule namespace split" do
    test "a token body referencing a lower_ident rule name is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        FOO := bar
        r := "x"
        """)

      assert error.message =~ "may only reference other tokens"
    end

    test "a rule containing an inline character class is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        r := [a-z]
        """)

      assert error.message =~ "inline character class"
    end

    test "a rule containing an inline /pattern/ is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        r := /a/
        """)

      assert error.message =~ "inline /pattern/"
    end

    test "a rule containing a bare '.' is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        r := .
        """)

      assert error.message =~ "'.' directly"
    end
  end

  describe "~ gap-override misuse" do
    test "~ in a @noskip grammar is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        @noskip
        FOO := "x"
        r := ~FOO
        """)

      assert error.message =~ "requires an active @skip"
    end

    test "~ followed by a quantifier is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        FOO := "x"
        r := ~FOO?
        """)

      assert error.message =~ "no capture and no quantifier"
    end
  end

  describe "duplicate declarations and dangling pragma references" do
    test "declaring the same token name twice is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        FOO := "x"
        FOO := "y"
        r := FOO
        """)

      assert error.message =~ "token FOO is already declared"
    end

    test "declaring the same rule name twice is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        r := "x"
        r := "y"
        """)

      assert error.message =~ "rule r is already declared"
    end

    test "@root naming an undefined rule is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root nope
        r := "x"
        """)

      assert error.message =~ "@root names undefined rule"
    end

    test "@skip naming an undefined token is rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        @skip NOPE
        r := "x"
        """)

      assert error.message =~ "@skip names undefined token"
    end
  end

  describe "/pattern/ rejects backreferences, named groups, and anchors" do
    test "backreferences are rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        NUM := /\1/
        r := NUM
        """)

      assert error.message =~ "backreferences"
    end

    test "named groups are rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        NUM := /(?<x>a)/
        r := NUM
        """)

      assert error.message =~ "named groups"
    end

    test "anchors are rejected" do
      error =
        fails(~S"""
        @grammar "t"
        @root r
        NUM := /^a/
        r := NUM
        """)

      assert error.message =~ "anchors"
    end
  end
end
