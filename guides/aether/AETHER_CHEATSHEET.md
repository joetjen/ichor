# Aether Cheatsheet

Quick syntax lookup. See [AETHER.md](AETHER.md) for full explanations.

## File skeleton

```text
@grammar "name"        ; required, must be first
@root rule_name         ; required, must be second
@skip TOKEN             ; optional -- default is @skip SPACE
@noskip                 ; optional -- mutually exclusive with @skip
@case_insensitive       ; optional

; comments run to end of line

TOKEN_NAME := ...        ; ALL_CAPS -- lexer, matched by maximal munch
rule_name  := ...        ; snake-case/kebab-case -- parser, ordered choice
```

## Operators

| Syntax        | Meaning                                    | Valid in           |
|---------------|---------------------------------------------|---------------------|
| `a b`         | sequence                                    | tokens & rules       |
| <code>a &#124; b</code> | ordered choice, first match wins  | tokens & rules       |
| `a*`          | zero or more                                | tokens & rules       |
| `a+`          | one or more                                 | tokens & rules       |
| `a?`          | zero or one                                 | tokens & rules       |
| `a{3}`        | exactly 3                                   | tokens & rules       |
| `a{3,}`       | 3 or more                                   | tokens & rules       |
| `a{3,7}`      | 3 to 7                                      | tokens & rules       |
| `&a`          | positive lookahead (consumes nothing)       | tokens & rules       |
| `!a`          | negative lookahead (consumes nothing)       | tokens & rules       |
| `( a )`       | grouping                                    | tokens & rules       |
| `name:a`      | named capture                               | rules only           |
| `~a`          | suppress `@skip` splicing before this term  | rules only           |
| `@indent(a)`  | `a` must start deeper than enclosing block  | rules only           |
| `@samecol(a)` | `a` must start at the enclosing column      | rules only           |
| `"lit"`       | string literal                              | tokens & rules*       |
| `[a-z]`       | character class                             | tokens only           |
| `[^a-z]`      | negated character class                     | tokens only           |
| `.`           | any single character                        | tokens only           |
| `/pattern/`   | regex-literal shorthand                     | tokens only           |

\* A bare string literal in a rule body is auto-promoted to a
compiler-generated anonymous token.

## String literal escapes

`\n` `\r` `\t` `\\` `\"` `\[` `\]` `\/` `\xHH` `\u{H+}` — any other
punctuation character escapes to itself (`\^`, `\-`, `\*`, ...).

## Case sensitivity

| Syntax     | Meaning                                              |
|------------|--------------------------------------------------------|
| `"lit"`    | case-sensitive, unless `@case_insensitive` is set       |
| `"lit"i`   | always case-insensitive                                |
| `"lit"cs`  | always case-sensitive, even under `@case_insensitive`   |

## Predefined tokens

| Token   | Default        |
|---------|-----------------|
| `DIGIT` | `[0-9]`         |
| `ALPHA` | `[a-zA-Z]`      |
| `ALNUM` | `DIGIT \| ALPHA` |
| `SPACE` | `[ \t\r\n]`     |
| `HEX`   | `[a-fA-F0-9]`   |

Redeclare any of them (`NAME := ...`) before first use to override the
default. `@skip NAME` (explicit or default) counts as an immediate use
of `NAME` at that point in the file.

## POSIX bracket classes

`[:alpha:]` `[:alnum:]` `[:digit:]` `[:space:]` `[:hex:]` — usable
inside `[...]`, mixed freely with ranges/literal characters:
`[[:alpha:]_][[:alnum:]_]*`.

## Regex-literal shorthand (tokens only)

| Supported                                    | Rejected                        |
|-----------------------------------------------|----------------------------------|
| literals, `.`, `[...]`/`[^...]`, `\|`, `(...)` | anchors `^` `$`                  |
| `*` `+` `?` `{n}` `{n,}` `{n,m}`               | backreferences `\1`-`\9`         |
| `(?=...)` `(?!...)`                           | named/unnamed groups `(?<...)`   |
| `\d` `\w` `\s` `\h` `\D` `\W` `\S` `\H`        |                                   |

## Maximal munch, in one sentence

At each lexer position: longest match wins; ties go to whichever token
was **declared first** in the file; a zero-width match never wins.

## Common gotchas

- A literal that's also a substring another token's character class
  would greedily match (e.g. a keyword `"end"` vs. an identifier token
  `[a-z]+`) ties in length — declare the keyword as its own real token,
  **before** the identifier token, so it wins.
- `@skip NAME` (even naming the *default* `SPACE`) marks `NAME` used
  immediately — you can't redeclare it afterward. Leave the pragma out
  entirely if you want to redefine the default `SPACE`'s own character
  set.
- Rules can't contain an inline `[...]`, `/pattern/`, or bare `.` —
  give it a token name first.
- `@samecol` checks against the nearest *enclosing* `@indent`'s column;
  with no enclosing `@indent`, that's column 0.
