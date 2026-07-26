# Aether Examples

Focused examples of individual Aether features, each small enough to read
in one go. For complete, larger grammars built from several of these
features at once, see [Ichor's own examples](../EXAMPLES.md) — LISP,
YAML, SQL, HTTP, regex, and more.

## Bounded repetition — a ZIP code

```text
@grammar "zip"
@root zip
@noskip

zip := DIGIT{5} ("-" DIGIT{4})?
```

```elixir
Grammar.VM.parse(grammar, "12345")      #=> {:ok, 5}
Grammar.VM.parse(grammar, "12345-6789") #=> {:ok, 10}
```

`{5}` requires exactly five digits; the optional `("-" DIGIT{4})?` group
handles the extended ZIP+4 form without a separate rule.

## Lookahead — a keyword that isn't a prefix of a longer word

```text
@grammar "kw"
@root kw
@noskip

END  := "end"
WORD := [a-z]+
kw   := END !WORD
```

```elixir
Grammar.VM.parse(grammar, "end")     #=> {:ok, 1}
Grammar.VM.parse(grammar, "endless") #=> {:error, %Ichor.Error{}}
```

`!WORD` (negative lookahead) requires that no `WORD` token starts right
where `END` left off, without consuming anything itself — the same
technique real keyword-vs-identifier disambiguation needs in any
language with reserved words. Notice `END` is declared as its own real
token, ahead of `WORD` in the file — both can match the literal text
`"end"` with the same length, and maximal munch breaks that tie by
declaration order.

## A custom `@skip` token, for whitespace *and* comments

```text
@grammar "cmt"
@root prog
@skip TRIVIA

SPACE   := [ \t\n]+
COMMENT := "#" (!"\n" .)* "\n"?
TRIVIA  := (SPACE | COMMENT)*
WORD    := [a-z]+

prog := WORD+
```

```elixir
Grammar.VM.parse(grammar, "a # comment\nb") #=> {:ok, 3}
```

`@skip TRIVIA` splices `TRIVIA*` between sequence elements instead of
the default `SPACE*` — since `TRIVIA` itself is defined as ordinary
whitespace *or* a comment, both are transparently skippable everywhere
the default `@skip` would only have skipped whitespace.

## Repeated named captures arrive as a list

```text
@grammar "csv"
@root row

WORD := [a-z]+
row  := first:WORD ("," rest:WORD)*
```

Parsing `"a,b,c"` gives an `Ichor.Actions` module
`handle_rule(:row, %{first: first, rest: rest}, ctx)` where `rest` is a
**list** of two captures (`b` and `c`) — always a list, even if the input
had been just `"a"` with no commas at all (`rest` would be `[]`, never a
missing key).

## `~` — suppressing automatic whitespace for one term

```text
@grammar "semver"
@root ver

WS     := [ ]+
DOT    := "."
NUMBER := DIGIT+

ver := NUMBER ~DOT NUMBER ~DOT NUMBER
```

```elixir
Grammar.VM.parse(grammar, "1.2.3")   #=> {:ok, 5}
Grammar.VM.parse(grammar, "1 . 2.3") #=> {:error, %Ichor.Error{}}
```

Every other sequence element still tolerates surrounding whitespace by
default (this grammar declares no `@skip`, so it uses the built-in
default); `~DOT` suppresses that tolerance for just the two dots, so a
version number can't have stray spaces around its own separators even
though the rest of the grammar is whitespace-tolerant.

## POSIX classes for identifiers

```text
@grammar "ident"
@root ident

IDENT := [[:alpha:]_][[:alnum:]_]*
ident := IDENT
```

```elixir
Grammar.VM.parse(grammar, "_private2") #=> {:ok, 1}
```

`[:alpha:]` and `[:alnum:]` reference the predefined `ALPHA`/`ALNUM`
tokens' own character sets, mixed freely with a literal `_` in the same
brackets — the common "identifier" pattern (letter or underscore, then
any number of letters/digits/underscores) without spelling out
`a-zA-Z0-9_` by hand.

## Case-insensitive keywords

```text
@grammar "bool"
@root bool
@case_insensitive

bool := "true" | "false"
```

```elixir
Grammar.VM.parse(grammar, "TRUE")  #=> {:ok, 1}
Grammar.VM.parse(grammar, "FaLsE") #=> {:ok, 1}
```

`@case_insensitive` applies to every bare quoted literal in the whole
grammar — useful for languages like SQL where keywords are
conventionally case-insensitive throughout.

## A regex-literal token, for compact character-level patterns

```text
@grammar "ip"
@root ip
@noskip

OCTET := /\d{1,3}/
DOT   := "."
ip    := OCTET DOT OCTET DOT OCTET DOT OCTET
```

```elixir
Grammar.VM.parse(grammar, "192.168.1.1") #=> {:ok, 7}
```

`/\d{1,3}/` desugars to the same `Grammar.IR` a hand-written
`DIGIT{1,3}` token body would produce — pure shorthand, valid only
inside a token body, never a real regex engine underneath. See the
[reference](AETHER.md#regex-literals) for exactly what the shorthand
supports.
