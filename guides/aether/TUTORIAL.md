# Aether Tutorial

This tutorial introduces Aether's own features one at a time, in the
order you're likely to need them, ending with a complete, working
grammar. It assumes you already know the basics of running a grammar
through Ichor — if not, read the [Ichor tutorial](../TUTORIAL.md) first.
This page is about Aether the *language*; see the
[reference](AETHER.md) for exhaustive detail on any single feature.

Every snippet below can be parsed and matched the same way:

```elixir
{:ok, grammar} = Aether.Parser.parse(source)
{:ok, grammar} = Grammar.Analysis.run(grammar)
Grammar.VM.parse(grammar, input)
```

## 1. The smallest grammar

Two pragmas are always required: `@grammar` names the grammar,
`@root` says which rule matching starts from.

```text
@grammar "greeting"
@root greeting

greeting := "hello"
```

```elixir
Grammar.VM.parse(grammar, "hello")   #=> {:ok, 1}
Grammar.VM.parse(grammar, "goodbye") #=> {:error, %Ichor.Error{}}
```

`greeting` is a **rule** (lowercase name) whose body is a single string
literal. Aether automatically promotes that literal into a
compiler-generated token behind the scenes — you never declared a token
yourself, and that's fine for a grammar this simple.

## 2. Tokens: `ALL_CAPS` names

A character class (`[a-z]`), a `/pattern/` literal, or a bare `.` can
only ever appear inside a token body, never a rule body directly — a
rule may only reference *named* tokens and rules. So once a pattern
needs character-level logic (a range, a repetition over characters)
rather than just a fixed string, give it a name as a real token:

```text
@grammar "greeting"
@root greeting

HELLO := "hello"
WORD  := [a-zA-Z]+

greeting := HELLO WORD
```

```elixir
Grammar.VM.parse(grammar, "hello world") #=> {:ok, 3}
```

Notice this already needs no special handling for the space between
`HELLO` and `WORD` — that's the next feature. Also notice `HELLO` is
declared as a real token here, not left as a bare `"hello"` literal the
way step 1 did: both `HELLO` and `WORD` can match `"hello"` itself, with
the same length, so this is a **maximal-munch tie** — and ties are
broken by declaration order. `HELLO` needs to come first in the file so
it wins that tie; see [the reference](AETHER.md#maximal-munch) for the
full rule.

## 3. Whitespace happens automatically

By default, every rule's sequence elements (after the first) get
whitespace-tolerance spliced in for free. You don't write it, and you
don't see it in the grammar text — it's just there. To turn it off
(needed once whitespace becomes meaningful, e.g. for HTTP or Markdown),
add `@noskip`:

```text
@grammar "tight"
@root pair
@noskip

pair := "a" "b"
```

```elixir
Grammar.VM.parse(grammar, "ab")   #=> {:ok, 2}
Grammar.VM.parse(grammar, "a b")  #=> {:error, ...}  -- no auto-skip here
```

## 4. Choice, repetition, and grouping

Standard PEG operators, first-match-wins for `|`:

```text
@grammar "list"
@root list

WORD := [a-z]+
list := WORD ("," WORD)*
```

```elixir
Grammar.VM.parse(grammar, "a,b,c") #=> {:ok, 5}
```

`?` (optional), `{n}`/`{n,}`/`{n,m}` (bounded repetition), and `&`/`!`
(lookahead predicates, matching nothing) round out the operator set —
see the [reference](AETHER.md#expression-syntax) for the complete list.

## 5. Naming what you capture

So far, matching only tells you *whether* input is valid. To get
structure back out for an `Ichor.Actions` module to work with, name the
parts you care about with `name:expr`:

```text
@grammar "pair"
@root pair

WORD := [a-z]+
pair := key:WORD "=" value:WORD
```

An `Ichor.Actions` module's `handle_rule(:pair, %{key: k, value: v}, ctx)`
now receives exactly those two captures. A bare reference to a *named*
token or rule (like `WORD` used without a `name:` prefix elsewhere)
is captured under its own name automatically — you only need `name:`
when you want a different name, or when the same thing is referenced
more than once in the same rule and needs to be told apart.

## 6. Case sensitivity

Individual literals can force a case either way with a suffix
(`"lit"i` always case-insensitive, `"lit"cs` always case-sensitive), or
the whole grammar can default every bare literal to case-insensitive:

```text
@grammar "kw"
@root stmt
@case_insensitive

SELECT := "select"
stmt   := SELECT
```

```elixir
Grammar.VM.parse(grammar, "SELECT") #=> {:ok, 1}
Grammar.VM.parse(grammar, "Select") #=> {:ok, 1}
```

## 7. A regex shorthand for token bodies

Token bodies (never rule bodies) can use a `/pattern/` literal as
shorthand for character-level matching, when writing the equivalent out
by hand would be tedious:

```text
NUMBER := /-?\d+(\.\d+)?/
```

This isn't a real regex engine — it desugars entirely into ordinary
Aether primitives at parse time, and deliberately rejects anything with
no meaningful PEG equivalent (anchors, backreferences, named groups).
See the [reference](AETHER.md#regex-literals) for exactly what's
supported.

## 8. Layout-sensitive grammars

`@indent(expr)` and `@samecol(expr)` (rule bodies only) give
YAML-style "this line must be indented under that one" structure
without treating whitespace as ordinary skippable trivia:

```text
@grammar "nested"
@root doc
@skip INLINE_WS

DASH      := "-"
NEWLINE   := "\n"
INLINE_WS := [ \t]*
WORD      := [a-z]+

doc      := @indent(list)
list     := item (NEWLINE @samecol item)*
item     := DASH WORD
```

```elixir
Grammar.VM.parse(grammar, "-a\n-b\n-c") #=> {:ok, 8}
```

Every `item` in the same `list` must line up in exactly the same
column — `@samecol` checks against the column `@indent` established
when the list began.

## 9. Putting it together

A tiny key-value config format, combining most of the above:

```text
@grammar "config"
@root config

SPACE  := [ \t\n]+
KEY    := [a-zA-Z_][a-zA-Z0-9_]*
STRING := "\"" (!"\"" .)* "\""
NUMBER := /-?\d+(\.\d+)?/

config := entry*
entry  := key:KEY "=" value:(STRING | NUMBER) ";"
```

No `@skip` pragma is declared here — leaving it out uses the default
skip mode with the built-in `SPACE` token. `SPACE` is redeclared above
with its own definition (equivalent to the default in this case, but it
didn't have to be) because it's redefined *before* anything actually
uses it; had this grammar written `@skip SPACE` explicitly, that
pragma itself would immediately count as a use, and the later
`SPACE := ...` line would be rejected as "already used" — see the
[reference](AETHER.md#predefined-tokens) for why.

```elixir
{:ok, grammar} = Aether.Parser.parse(source)
{:ok, grammar} = Grammar.Analysis.run(grammar)
Grammar.VM.parse(grammar, ~S(name = "ichor"; version = 1;))
#=> {:ok, 10}
```

Pair this with an `Ichor.Actions` module implementing `handle_rule(:config,
%{entry: entries}, ctx)` and `handle_rule(:entry, %{key: k, value: v}, ctx)`
to fold the whole thing into a real `%{String.t() => term()}` map — see the
[Ichor tutorial](../TUTORIAL.md#6-giving-meaning-ichoractions) for exactly
that pattern, or [Aether examples](AETHER_EXAMPLES.md) for more complete,
runnable grammars.
