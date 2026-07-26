# Aether Reference

Aether is Ichor's own grammar language. This page documents every
feature in detail. If you're new to Aether, read the
[tutorial](TUTORIAL.md) first — this page is a reference, not an
introduction.

## File structure

Every grammar starts with two required pragmas, in order:

```text
@grammar "name"
@root rule_name
```

`@grammar` names the grammar (informational). `@root` names the rule
where matching begins. After those, zero or more of the optional
pragmas below may follow, in any order, each at most once. Then the
grammar's token and rule definitions follow, in any order — a
definition may reference a name declared later in the file.

Comments run from `;` to the end of the line.

## Tokens vs. rules

This is the one syntactic distinction Aether's entire design hinges on:

- A name in `ALL_CAPS` (matching `[A-Z_][A-Z0-9_]*`) declares a
  **token**. Tokens are matched by the *lexer*, directly against raw
  characters.
- A name in `snake-case` or `kebab-case` (matching `[a-z][a-z0-9_-]*`)
  declares a **rule**. Rules are matched by the *parser*, over the
  token stream the lexer already produced — never over raw characters
  directly.

Every Aether grammar compiles to a genuine two-stage Lexer -> Parser,
never a single scannerless pass. This has real consequences:

- A rule body may only reference tokens and other rules — never an
  inline character class, `/pattern/` regex literal, or bare `.`
  ("any character"). Those are lexer-only constructs; give the pattern
  a name as a token instead, and reference that token from the rule.
- A token body may reference other tokens, but never a rule.
- Writing a bare string literal (`"SELECT"`) directly inside a *rule*
  body is allowed as a convenience — Aether automatically promotes it
  to a compiler-generated anonymous token behind the scenes, since only
  tokens ever participate in lexing. The same literal text (with the
  same case-sensitivity) reuses the same anonymous token wherever it
  appears.
- A bare string literal directly inside a *token* body is just an
  ordinary sub-match — no promotion needed, since it's already inside a
  token.

### Maximal munch

At every position, the lexer tries every token the grammar's rules can
actually reach (directly referenced by some rule, or the active `@skip`
token) and picks the **longest match**. Ties are broken by **declaration
order** — the token declared first in the file wins. A token that can
match zero characters is never accepted as "the next token" (it would
never advance, and tokenizing would never finish); such a token can
still exist and be referenced from *inside* another token's own
definition, it just can never win the top-level race on its own.

This is why declaration order sometimes matters even between tokens
that look unrelated: if two tokens can match the same text at the same
position with the same length, whichever is declared first in the file
wins.

### Rule parsing: ordered PEG choice

Once tokenized, rules are matched using ordinary PEG semantics: within
a `first | second | third`, the *first* alternative that matches wins,
even if a later alternative could also have matched (possibly matching
more, or less). There's no most-specific-wins or longest-match rule at
the parser level the way there is at the lexer level — order in the
source is the only thing that decides among rule alternatives, so put
more specific alternatives first.

## Expression syntax

From lowest to highest precedence:

```text
choice      := sequence ("|" sequence)*
sequence    := term+
term        := ("~")? (name ":")? postfix
postfix     := ("&" | "!")? primary ("*" | "+" | "?" | "{" bound "}")?
primary     := STRING | CHAR_CLASS | REGEX | "." | UPPER_IDENT | lower_ident
             | "(" choice ")" | "@indent(" choice ")" | "@samecol(" choice ")"
```

| Operator            | Meaning                                                         |
|----------------------|-----------------------------------------------------------------|
| `a b`                | sequence -- `a` then `b`                                        |
| <code>a &#124; b</code> | ordered choice -- `a`, or (if `a` fails) `b`                 |
| `a*`                 | zero or more, greedy                                            |
| `a+`                 | one or more, greedy                                             |
| `a?`                 | zero or one                                                     |
| `a{3}`               | exactly 3                                                       |
| `a{3,}`              | 3 or more                                                       |
| `a{3,7}`             | between 3 and 7                                                 |
| `&a`                 | positive lookahead -- consumes nothing                          |
| `!a`                 | negative lookahead -- consumes nothing                          |
| `name:a`             | named capture                                                   |
| `~a`                 | suppress `@skip` splicing before this term (rule bodies only)   |
| `( a )`              | grouping                                                        |
| `.`                  | any single character (tokens only)                              |

Quantifiers, predicates, and grouping all work identically in both
token and rule bodies (subject to the token/rule leaf restrictions
above).

## Whitespace: `@skip` / `@noskip` / `~`

By default (no `@skip`/`@noskip` pragma given at all), every rule's
sequence elements — after the first — get an automatic `SPACE*` spliced
in front of them, where `SPACE` is the built-in predefined token
(overridable). This is what lets `expr := term "+" term` tolerate
`"1 + 2"` and `"1+2"` alike without writing whitespace tolerance into
every single rule by hand.

- `@skip TOKEN` uses a different token in place of `SPACE` — useful
  when comments should also be treated as skippable trivia (a common
  pattern: declare a `TRIVIA := (SPACE | COMMENT)*` token and
  `@skip TRIVIA`).
- `@noskip` disables splicing entirely. Required for any grammar where
  whitespace is meaningful syntax, not filler — HTTP headers, regex
  patterns, Markdown.
- `~name` (only valid in rule bodies, only directly prefixing a bare
  token or rule reference with no capture and no quantifier) suppresses
  splicing before that one specific term, for the rare case where two
  adjacent things must not have skippable trivia between them even
  though the rest of the rule does.

Splicing also applies to the repeated body of `*`/`+`/`{n,m}` — `form*`
tolerates whitespace *between* repetitions, not just around the whole
group, since each repetition is itself another sequence element.

## Predefined tokens

Five tokens exist in every grammar even if never declared:

| Token    | Default definition            |
|----------|--------------------------------|
| `DIGIT`  | `[0-9]`                        |
| `ALPHA`  | `[a-zA-Z]`                     |
| `ALNUM`  | `DIGIT \| ALPHA`                |
| `SPACE`  | `[ \t\r\n]`                     |
| `HEX`    | `[a-fA-F0-9]`                   |

Any of the five may be redeclared with `NAME := ...`, as long as the
redeclaration happens **before** the token is used anywhere in the file
(including implicitly, e.g. `@skip`'s own default use of `SPACE`, or a
POSIX bracket class referencing one of the other four). Using one first
and then trying to redeclare it is a compile error — the two orderings
would otherwise mean different things depending on where in the file
the use occurred, which Aether rejects outright rather than resolving
by File order.

## POSIX bracket classes

Inside a character class (`[...]`), `[:alpha:]`, `[:alnum:]`,
`[:digit:]`, `[:space:]`, and `[:hex:]` reference the identically-named
predefined token, and can be freely mixed with ordinary ranges and
characters in the same brackets:

```text
IDENT := [[:alpha:]_][[:alnum:]_]*
```

## Character classes

`[...]` matches one character from the given set; `[^...]` negates it
(matches one character *not* in the set — but still requires a
character to be present; it never matches at end of input). Contents
are a mix of single characters, `a-z`-style ranges, POSIX names, and
escape sequences. A `-` immediately before the closing `]` is a literal
dash, not a range operator.

## String literals

Double-quoted, with these escapes: `\n` `\r` `\t` `\\` `\"` `\[` `\]`
`\/`, `\xHH` (exactly two hex digits), `\u{H+}` (one or more hex
digits), and any other punctuation character escapes to itself (`\^`,
`\-`, `\*`, and so on) — convenient for writing character-class-like
escapes consistently in both contexts.

A quote suffix controls case sensitivity for that one literal,
overriding the grammar-level `@case_insensitive` setting either way:

- `"lit"` — case-sensitive, unless `@case_insensitive` is set for the
  whole grammar (then case-insensitive).
- `"lit"i` — always case-insensitive, regardless of the grammar-level
  setting.
- `"lit"cs` — always case-sensitive, regardless of the grammar-level
  setting.

## `@case_insensitive`

A grammar-wide pragma: every bare (`"lit"`, no suffix) string literal
matches either case. Doesn't affect character classes or `[:posix:]`
classes — only quoted string literals.

## Regex literals

Token bodies only (never valid in a rule body) — `/pattern/` is a
convenience shorthand that desugars entirely into ordinary Aether
primitives before reaching `Grammar.IR`. It is **not** a real regex
engine wired in underneath; support is deliberately partial:

Supported: literal characters, `.` (any character), character classes
(`[...]`/`[^...]`, POSIX names included), alternation (`|`), grouping
(`(...)`), quantifiers (`*` `+` `?` `{n}` `{n,}` `{n,m}`), positive/
negative lookahead (`(?=...)` / `(?!...)`), and the shorthand classes
`\d` `\w` `\s` `\h` (referencing `DIGIT`/`ALNUM`/`SPACE`/`HEX`) with
their negated forms `\D` `\W` `\S` `\H`.

Explicitly rejected, with a normal `Ichor.Error` rather than silently
doing the wrong thing: anchors (`^` `$`), backreferences (`\1`-`\9`),
and named/unnamed capturing groups (`(?<name>...)`) — none of these have
a meaningful desugaring into PEG-style matching primitives, so Aether
refuses them outright instead of pretending to support them.

```text
NUMBER := /\d+(\.\d+)?/
```

## Indentation sensitivity

Two pragmas, valid only inside rule bodies, for layout-sensitive
grammars (YAML-style structure) without requiring a scannerless parser
to special-case columns everywhere:

- `@indent(expr)` — `expr` must start at a column strictly greater than
  the currently active reference column, and its own starting column
  becomes the new reference column for anything nested inside it.
- `@samecol(expr)` — `expr` must start at *exactly* the currently
  active reference column (no descending further).

Both also accept a single bare term with no parens as sugar for
wrapping just that one term: `@samecol pair` is shorthand for
`@samecol(pair)`.

`@samecol` always checks against the nearest *enclosing* `@indent`'s
reference column — with no enclosing `@indent` anywhere, the reference
column defaults to 0, so `@samecol` at the very top of a grammar only
succeeds on something starting in the first column. In practice
`@samecol` is used nested inside an `@indent`, as below, not standalone.

```text
mapping := pair (NEWLINE @samecol pair)*
pair     := SCALAR COLON (inline_value | NEWLINE @indent(block_value))
```

## Named captures

`name:expr` captures `expr`'s matched value under `name`, available to
an `Ichor.Actions` module as `captures.name` (as a
`%{name => Ichor.Capture.t()}` — see the [tutorial](../TUTORIAL.md) for
how Actions modules consume these). A bare reference to a *named*
token or rule (no explicit `name:` prefix) is implicitly captured under
its own name automatically — `factor` in `expr := term (op:("+" | "-")
term)*` needs no `term:term`, it already shows up as `:term`. A bare
reference to a compiler-generated anonymous token (an inline literal
like `"("`, never a name the grammar author chose) gets **no** implicit
capture — writing a bare literal is precisely how a grammar author says
"I don't care about matching this," and an explicit `paren:"("` still
works if that literal's value actually is wanted.

A capture whose expression sits under a `*`/`+`/`{n,m}` anywhere in
the rule always arrives as a **list** in `Ichor.Actions`, even if it
matched zero or exactly one time — never a bare value, and never a
missing key, so pattern-matching on capture shape is reliable regardless
of how many times something actually matched.
