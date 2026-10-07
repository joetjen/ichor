# `mix ichor.tokens`

Lists every token a grammar declares, in the exact order the Lexer's
maximal-munch tie-break uses. Useful whenever you need to know *why* two
tokens compete for the same input, without running the rest of the
pipeline — see the [cheatsheet](../CHEATSHEET.md#inspect-a-grammars-tokens)
for the one-line version.

```sh
mix ichor.tokens PATH_TO_GRAMMAR
```

`PATH_TO_GRAMMAR` must be `.aether` source — unlike
[`mix ichor.gen`](ICHOR_GEN.md), this task doesn't go through
`Ichor.GrammarImport`, so ABNF/BNF/EBNF/PEG grammars aren't accepted
here.

## Why maximal-munch order matters

Aether's Lexer always prefers the *longest* match at a given position;
`token_order` only breaks ties when two tokens match the same length —
e.g. a keyword like `SELECT` against the general `IDENT` token. Getting
that tie-break order wrong silently reclassifies input (an identifier
named `selection` matching as `SELECT` plus leftover `ion`, say). `mix
ichor.tokens` prints the order the Lexer actually committed to, so you
can check it against what you expect before it turns into a confusing
runtime bug.

## What it shows

Three kinds of tokens, in a single `token_order`-sorted table:

- **`declared`** — tokens your grammar names explicitly (`NUMBER :=
  ...`).
- **`anonymous`** — tokens auto-promoted from an inline string literal
  used directly in a rule (e.g. `"+"` inside `expr := term (op:("+" |
  "-") term)*`), so the Lexer still tokenizes it consistently even
  though the grammar never gave it a name.
- **`predefined`** — the five tokens every grammar gets whether it uses
  them or not: `DIGIT`, `ALPHA`, `ALNUM`, `SPACE`, `HEX`. Always present
  in the table, whether left at their built-in pattern or overridden in
  the grammar source.

Only needs the Aether front-end to run — no analysis pass, no VM/native
backend — so it works on any grammar that *parses*, even one that would
later fail the left-recursion/reference-check analysis pass. That makes
it useful for inspecting a grammar mid-edit, before it's necessarily
valid enough to compile.

## Example

Given a calculator grammar:

```text
@grammar "calculator"
@root expr

NUMBER := DIGIT+ ("." DIGIT+)?

expr   := term (op:("+" | "-") term)*
term   := factor (op:("*" | "/") factor)*
factor := NUMBER | "(" expr ")"
```

```sh
$ mix ichor.tokens calculator.aether
#   NAME    KIND        PATTERN
1   NUMBER  declared    DIGIT+ ("." DIGIT+)?
2   ANON_1  anonymous   "+"
3   ANON_2  anonymous   "-"
4   ANON_3  anonymous   "*"
5   ANON_4  anonymous   "/"
6   ANON_5  anonymous   "("
7   ANON_6  anonymous   ")"
8   DIGIT   predefined  [0-9]
9   ALPHA   predefined  [a-zA-Z]
10  ALNUM   predefined  [0-9] | [a-zA-Z]
11  SPACE   predefined  [ \u{9}\u{D}\u{A}]
12  HEX     predefined  [a-fA-F0-9]
```

`NUMBER` is declared, so it sorts first; the six bare string literals
(`"+"`, `"-"`, `"*"`, `"/"`, `"("`, `")"`) each got auto-promoted to
their own anonymous token (`ANON_1`...`ANON_6`, numbered in the order
they were first seen); and all five predefined tokens close out the
table at their default patterns, even though this grammar never
references `ALPHA` or `HEX` directly — `ALNUM`'s own default is a
choice between `DIGIT` and `ALPHA`, which is why it still appears
composed from them in the `PATTERN` column.

## Example: an overridden predefined token

Overriding a predefined token in the grammar source changes its
`PATTERN` column but not its `predefined` kind or its position in
`token_order`:

```text
@grammar "identifiers"
@root program

ALPHA := [a-zA-Z_]

program := ALPHA+
```

```sh
$ mix ichor.tokens identifiers.aether
#  NAME   KIND        PATTERN
1  ALPHA  predefined  [a-zA-Z_]
2  DIGIT  predefined  [0-9]
3  ALNUM  predefined  [0-9] | [a-zA-Z_]
4  SPACE  predefined  [ \u{9}\u{D}\u{A}]
5  HEX    predefined  [a-fA-F0-9]
```

`ALNUM`'s pattern picks up the override too, since its own default is
defined in terms of `DIGIT`/`ALPHA` rather than a fixed pattern of its
own.

## See also

- [`mix ichor.gen`](ICHOR_GEN.md) — compile a grammar once it's ready, instead of just inspecting it.
- [Cheatsheet](../CHEATSHEET.md#inspect-a-grammars-tokens) — quick reference.
- `Grammar.Tokens` — the module this task is a thin CLI wrapper around, if you need the same introspection from inside Elixir code.
