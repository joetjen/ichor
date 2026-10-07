# Aether in Aether

Aether's own syntax, written as an Aether grammar. Ichor doesn't read
`.aether` files with this grammar — `Aether.Lexer` and `Aether.Reader`
are hand-written — so this is a description, kept honest by a test
rather than by being the implementation: `test/aether/grammar_doc_test.exs`
compiles the block below and checks that it accepts exactly the files
`Aether.Reader` accepts, across every `.aether` file in this repository
and a set of deliberately broken ones.

See the [reference](AETHER.md) for what each construct means; this page
only says what is well-formed.

## The grammar

```text
@grammar "aether"
@root grammar_file
@skip TRIVIA

COMMENT := ";" (!"\n" .)*
TRIVIA  := (SPACE | COMMENT)*

UPPER_NAME := [A-Z_] [A-Z0-9_]*
LOWER_NAME := [a-z] [a-z0-9_\-]*
NUMBER     := DIGIT+

ESCAPE     := "\\" ("x" HEX HEX | "u{" HEX+ "}" | [nrt] | [^a-zA-Z0-9])
STRING     := "\"" (ESCAPE | !"\"" .)* "\"" (("cs" | "i") ![a-zA-Z0-9_] | !"cs" !"i")
POSIX      := "[:" ("alpha" | "alnum" | "digit" | "space" | "hex") ":]"
CHAR_CLASS := "[" "^"? (POSIX | ESCAPE | !"]" .)* "]"
REGEX      := "/" ("\\" . | "[" ("\\" . | !"]" .)* "]" | ![/\[] .)* "/"

grammar_file := TRIVIA? header definition* TRIVIA?

header := "@grammar" name:STRING "@root" root:LOWER_NAME pragma*
pragma := "@skip" UPPER_NAME | "@noskip" | "@case_insensitive" | "@engine" LOWER_NAME

definition   := token_def | rule_def | keywords_def
token_def    := UPPER_NAME ":=" choice refine?
rule_def     := LOWER_NAME ":=" choice
keywords_def := "@keywords" UPPER_NAME "{" keyword ("," keyword)* "}"
keyword      := STRING "->" UPPER_NAME
refine       := "@refine" "(" STRING "," STRING ("," UPPER_NAME)* ")"

choice     := sequence ("|" sequence)*
sequence   := (!def_head item)+
def_head   := (UPPER_NAME | LOWER_NAME) ":="
item       := "~"? term
term       := (LOWER_NAME ":")? postfix
postfix    := ("&" | "!") primary | primary quantifier?
quantifier := "*" | "+" | "?" | "{" NUMBER ("," NUMBER?)? "}"
primary    := STRING | CHAR_CLASS | REGEX | "." | UPPER_NAME | LOWER_NAME
            | "(" choice ")" | layout | native

layout     := ("@indent" | "@samecol") ("(" choice ")" | postfix)
native     := "@native" "(" STRING "," STRING ("," LOWER_NAME)* ")" hint?
hint       := "@hint" "(" hint_entry ("," hint_entry)* ")"
hint_entry := LOWER_NAME ":" (LOWER_NAME | "(" (LOWER_NAME ("," LOWER_NAME)*)? ")")
```

## Reading it

- **Upper-case names are tokens, lower-case names are rules** — the
  same split the grammar describes. `UPPER_NAME` and `LOWER_NAME` are
  exactly `Aether.Lexer`'s two identifier shapes; anything else, like
  `Foo`, matches neither and fails to lex.
- **`sequence` stops in front of `NAME :=`.** That lookahead is the
  whole reason a definition needs no terminator: a bare name is
  otherwise a perfectly good next term.
- **`TRIVIA?` at both ends of `grammar_file`** because `@skip` only
  splices between the parts of a rule, never before the first or after
  the last — a file may begin with a comment and end with a newline.
- **Pragmas are header-only.** `pragma*` sits inside `header`, so a
  `@skip` written after the first definition is a syntax error, as it
  is for `Aether.Reader`.

## Beyond syntax

`Aether.Reader` checks more than a context-free grammar can say. It
also rejects:

- a character class, `.` or `/regex/` in a rule body, and a rule name
  in a token body;
- a `name:` capture in a token body — a token matches as one piece of
  text;
- `~` anywhere but directly before a bare name, inside a token, or
  under `@noskip`;
- a pragma given twice, `@skip` together with `@noskip`, and an
  `@engine` other than `peg`, `lr` or `glr`;
- a name declared twice, and both `@keywords` and `@refine` on one
  token;
- in `@hint`, keys other than `nullable` and `leading`, `leading:` in
  a token, and a `leading:` name that isn't a dependency.

Undefined references, redeclared predefined tokens and left recursion
are checked later, by `Aether.Eval` and `Grammar.Analysis`, once the
whole grammar has been read.
