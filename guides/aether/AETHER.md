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

## `@engine`

A grammar-wide pragma picking the parsing algorithm for `@root`:

```text
@engine peg   ; the default -- ordered-choice recursive descent
@engine lr    ; deterministic shift-reduce, requires a conflict-free grammar
@engine glr   ; Tomita-style GLR, forks at genuine ambiguity
```

Independent of which backend runs the grammar (`Grammar.VM` or
`Grammar.Native`, i.e. `use Ichor`) — both support all three engines.
`peg` (the default, so every grammar written before `@engine` existed
keeps behaving identically) is ordinary top-down recursive descent: the
first matching alternative wins, and left recursion is rewritten away by
`Grammar.Analysis` automatically. `lr`/`glr` are bottom-up shift-reduce
parsers built from a from-scratch SLR(1) table instead — the natural fit
for **left-recursive** rules (`expr := expr "+" term | term`, not the
PEG-idiomatic `term ("+" term)*`), which PEG can't parse at all but
bottom-up parsing handles natively. `Grammar.Analysis` skips its
left-recursion rewrite entirely for `lr`/`glr` grammars, since it would
undo the very shape they want.

- **`lr`** requires the resulting table be conflict-free — an ambiguous
  or genuinely context-free (non-regular-per-rule) grammar is rejected
  at compile/analysis time, naming the conflicting state and
  productions, rather than silently picking one arbitrarily.
- **`glr`** accepts conflicts and forks at them, exploring every viable
  parse in parallel via a graph-structured stack that shares/merges
  history at points where forks reconverge — this is what recovers
  inputs plain PEG's greedy, never-reconsidered commit can't (a
  `rule := "ab" | "a"` alternative that "wins" too early, with nothing
  left over for what follows), and what lets a grammar express genuine
  ambiguity (natural-language-style, or the classic dangling-`else`
  problem) instead of being forced to silently favor one reading. When
  more than one derivation survives to the end of input, the earliest
  point the derivations disagree decides the winner, by **declared
  order** — same convention ordinary PEG choice already uses (whichever
  alternative/production was written first in the source wins), with one
  refinement: at a conflict cell offering both a shift and a reduce, the
  shift always wins (matching yacc/bison's own default), which is what
  makes the dangling-`else` case resolve the way every real language
  resolves it (`else` binds to the nearest open `if`) with no
  special-casing anywhere.

Only `Seq`/`Choice`/`Star`/`Plus`/`Opt`/`Rep`/`RuleRef`/`Capture` are
supported inside an `lr`/`glr` rule — `&`/`!` lookahead predicates,
`@indent`/`@samecol`, and rule-position `@native(...)` all need
arbitrary backtracking or side-channel state a shift-reduce table has no
room for, and are rejected with a build-time error naming the rule and
construct. Token-level lexing (including token-position
`@native(...)`) is unaffected either way — `lr`/`glr` still parse the
same Tokenizer/Lexer-produced token stream a `peg` grammar would.

```text
@grammar "calculator"
@root expr
@engine lr

NUMBER := /\d+(\.\d+)?/
PLUS   := "+"

expr := expr PLUS term | term
term  := NUMBER
```

See `Grammar.LR`/`Grammar.GLR` (interpreted) and `Grammar.Native.LR`/
`Grammar.Native.GLR` (compiled) for the engines themselves, and
`Grammar.LRTable` for the shared SLR(1) table construction both draw on.

## `@keywords` / `@refine`

Reclassify a token *after* the Tokenizer matches it, *before* the Parser
ever sees it — for a lexical distinction maximal munch alone can't make,
because it depends on the token's own text (a keyword vs. an ordinary
identifier with the same shape) or on what came immediately before it
(JavaScript's `/`, which starts either a regex literal or a division
operator depending on the preceding token).

`@keywords` is sugar for the common table-lookup case:

```text
WORD := [a-zA-Z_][a-zA-Z0-9_]*
@keywords WORD { "if" -> KEYWORD_IF, "return" -> KEYWORD_RETURN }
```

Every `WORD` token whose exact text matches a key in the table is
renamed to the corresponding target token (`KEYWORD_IF`, `KEYWORD_RETURN`);
anything else stays `WORD`. The target names never need their own
`TOKEN := ...` declaration — `@keywords` is what tells `Grammar.Analysis`
and the lexable-candidate-set computation they exist.

`@refine("Module", "function", ...)` is the escape hatch for anything
needing real logic instead of a fixed table — attached directly to a
token's own definition:

```text
SLASH := "/" @refine("JS.SlashDisambiguator", "refine", DIV, REGEX_START)
```

The callback (`c:Ichor.TokenRefiner.refine/4`: `raw_name`, `raw_text`,
`pos :: {line, column}`, and `preceding` — every token already
reclassified so far, in final form, which is what makes the
lookbehind-dependent JS case work) returns `{:ok, new_name, value}` (the
new token name plus a capture-value override, e.g. a decoded escape
sequence reaching `Ichor.Actions` instead of raw source text) or
`{:error, reason}`, surfaced as an `Ichor.Error` with `stage: :lexer`.

## `@native` / `@hint`: the escape hatch

For the rare case a grammar's own meaning is mutated mid-file by
something declared earlier — Prolog's runtime-extensible operator table
(`op/3`), Haskell fixity declarations, a heredoc whose terminator is
read off the source itself, a string literal with embedded interpolated
expressions — no static grammar (PEG, LR, or GLR) can express the rule
or token directly. `@native("Module", "function", dep, ...)` hands that
one rule or token to hand-written Elixir instead.

### At rule position (`Grammar.IR.Custom`)

```text
expr := @native("Prolog.Grammar", "parse_term", primary) @hint(nullable: false, leading: (primary))
```

`deps` (`primary` above) lists the *only* other rules the callback is
allowed to call back into, via a `rule_matchers` map restricted to
exactly those names — kept explicit so `Grammar.Analysis`'s reference
check still sees this node's real dependencies even though its own body
is opaque Elixir code. The callback (matching `c:Ichor.CustomRule.match/4`,
though it doesn't have to be named `match` — `@native`'s own second
argument names it explicitly) is:

```elixir
@callback match(stream, pos, context, rule_matchers) ::
            {:ok, new_pos, Ichor.Capture.node_t()} | :fail
```

- `stream`/`pos` — the same compiled token stream and position any
  ordinary rule matcher works over.
- `context` — read-only: whatever the *previous* top-level form's own
  evaluation produced (via `Grammar.VM.run_sequence/4`/
  `Grammar.Native`'s generated `run_sequence/2`), or `initial_context`
  outside a sequence. This is how a `:- op(700, xfx, is).` directive
  parsed earlier in the same file can extend the operator table a later
  clause's own `@native` callback parses against.
- `rule_matchers` — `%{primary: (stream, pos -> {:ok, new_pos, node} | :fail)}`
  for the example above: call straight back into the grammar's own
  compiled `primary` rule.

`@hint(nullable: bool, leading: (dep, ...))` supplies the two facts
`Grammar.Analysis` would otherwise compute by walking the rule's own
structure, impossible here since the body is arbitrary code: `nullable`
defaults to `false` (most custom recognizers consume something),
`leading` defaults to every declared dependency (conservative, for
left-recursion-cycle detection). `Ichor.Toolkit.Pratt` is built exactly
for writing this kind of callback — precedence-climbing over a
runtime-mutable operator table is the single most common reason to reach
for rule-position `@native` at all.

### At token position (`Grammar.IR.CustomLexeme`)

```text
STRING := @native("JS.StringInterp", "scan", expr) @hint(nullable: false)
```

Always stands alone as an entire token definition — it can't be
referenced from inside another token's body, and can't be composed
inside a larger token expression. `deps` here names *rules* (never other
tokens — the one narrow exception to "a token body may only reference
other tokens"), reachable through a re-lex-from-a-character-position
primitive rather than the token-stream-based `rule_matchers` rule
position gets:

```elixir
@callback scan(input, context, rule_matchers) ::
            {:ok, text, rest, Ichor.Capture.node_t() | nil} | :fail
```

- `input` — the *remaining suffix* of the source text (not a position
  into some original string).
- `context` — same meaning as `c:Ichor.CustomRule.match/4`'s.
- `rule_matchers` — `%{expr: (input -> {:ok, text, rest, capture} | :fail)}`
  for the example above: re-lexes `input` from scratch and matches the
  named rule, for a token that needs to recurse into full rule-level
  parsing mid-scan (an embedded `#{expr}` inside a string literal) —
  something a fixed maximal-munch tokenizer has no way to express on its
  own.

Returns `{:ok, text, rest, capture}` with `text <> rest == input`.
`capture` is normally `nil` (this token behaves like any other — a plain
`{:token, name, text}` downstream); a string-interpolation token
overrides it with an explicit `Ichor.Capture.node_t()` instead, so its
embedded expressions' own parsed structure reaches `Ichor.Actions`
intact rather than collapsing into flat text. `@hint(nullable: bool)` is
the only hint here (`false` by default) — there's no `leading`, since
left-recursion-cycle detection is a rule-level concept only.
