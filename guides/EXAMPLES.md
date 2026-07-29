# Examples

The [tutorial](TUTORIAL.md) builds one example — a calculator — from
nothing. This page walks through several more, chosen to cover different
shapes of problem and different corners of `Ichor.Actions`. Each
grammar's full source lives under `test/<name>/<name>.aether` in the
repository, alongside the test suite that exercises it on both backends.

## LISP — special forms and deferred evaluation

A minimal Clojure-inspired LISP, the example that proves out
`Ichor.Actions`'s thunk-based design: special forms like `if` and `quote`
need to control *whether* and *when* their arguments are evaluated, not
just fold over already-evaluated values the way the calculator's `expr`/
`term` do.

```text
@grammar "lisp"
@root form
@skip TRIVIA

SYMBOL_START := [[:alpha:]_+\-*/<>=!?]
SYMBOL_CHAR  := [[:alnum:]_+\-*/<>=!?]
SYMBOL       := SYMBOL_START SYMBOL_CHAR*
KEYWORD      := ":" SYMBOL
STRING       := "\"" (!"\"" .)* "\""
NUMBER       := "-"? DIGIT+ ("." DIGIT+)?
COMMENT      := ";" (!"\n" .)* "\n"?
SPACE        := [ \t\n,]+
TRIVIA       := (SPACE | COMMENT)*

form  := list | vector | map | reader_macro | atom
list  := "(" form* ")"
atom  := SYMBOL | KEYWORD | STRING | NUMBER
```

*(abridged — the full grammar also has `vector`/`map` literals and reader
macros for `'`/`` ` ``/`~`/`~@`/`^`)*

The Actions module implements `if`, `quote`, `fn`, `def`, `cond`, and
`defmacro` as core special forms — each one receiving its arguments as
unevaluated `Ichor.Capture`s and deciding for itself which to call `.eval`
on. `(if 1 (quote yes) (quote no))` evaluates to `yes` without ever
evaluating the untaken `no` branch — which matters: an untaken branch is
allowed to contain code that would error, or never terminate, and it
still must not run. Everything else (`let`, `when`, `and`, `or`) is
defined *in LISP itself*, as macros over those six primitives, loaded via
`Grammar.VM.run_sequence/4` — proof that the six core forms are actually
sufficient, not just a hand-picked list.

## YAML — structure with zero custom actions

A mapping/sequence fragment of YAML, demonstrating the opposite end of
the spectrum from LISP: sometimes a grammar needs no `Ichor.Actions`
callbacks at all.

```text
@grammar "yaml"
@root document
@skip INLINE_WS

document      := (root_mapping | root_sequence | scalar_doc) NEWLINE*
root_mapping  := @indent( mapping )
mapping       := pair (NEWLINE @samecol pair)*
pair          := SCALAR COLON (inline_value | NEWLINE @indent(block_value))
```

`@indent(...)` and `@samecol` give Aether layout-sensitivity (a value
under a key must be indented deeper; sibling keys must line up in the
same column) without a scannerless parser having to special-case columns
everywhere — see the [Aether reference](aether/AETHER.md#indentation-sensitivity)
for how they work. With `Support.NoActions` (a module implementing no
callbacks at all) as the Actions module, the default fallback alone
produces a plain `Ichor.Node` tree; a small `materialize` pass then walks
that tree and turns it into an ordinary Elixir map/list —
`"name: ichor\ntags:\n  - grammar\n  - parser"` becomes
`%{"name" => "ichor", "tags" => ["grammar", "parser"]}`. The grammar does
all the real work; the "Actions" are just a tree-to-map conversion.

## LogQL and SQL — executing a query against real data

Both grammars parse a small query language and, unlike LISP or YAML,
their Actions module doesn't just produce a value — it **executes** the
query against a data source (rows or log streams) passed in through
`Ichor.Actions`'s own `context`:

```text
@grammar "sql"
@root select_stmt
@case_insensitive

select_stmt := SELECT column_list FROM table_ref where_clause?
```

`@case_insensitive` makes every bare quoted literal in the grammar match
either case, so `select`/`Select`/`SELECT` are all the same token — a
one-line pragma standing in for what would otherwise be a case-insensitive
variant of every keyword token. `SQL.Actions.handle_rule(:select_stmt,
...)` reads `context` for the actual rows, filters/projects them
according to the parsed `where_clause`/`column_list`, and returns the
result set — the grammar describes valid syntax, the Actions module
supplies what to run it against.

## HTTP — when the grammar alone isn't enough

A request-line-plus-headers fragment of HTTP/1.1, demonstrating a
genuine limit of what a context-free grammar can express on its own:

```text
@grammar "http"
@root request
@noskip

request := request_line header* CRLF body?
body    := content:((WORD | SP | COLON | CRLF)*)
```

`@noskip` turns off Aether's automatic whitespace-splicing entirely —
essential here, since HTTP's own whitespace (a single required space
after a header's `:`, literal `\r\n` line endings) is meaningful syntax,
not something to skip past. But no context-free grammar can express "the
body is exactly `Content-Length` bytes long" — that number lives in an
already-parsed header, not in the grammar's own shape. `HTTP.Actions`
resolves this the straightforward way: the grammar matches the
*maximum* possible body (everything until the input ends), and the
Actions module's `handle_rule(:request, ...)` reads the already-evaluated
`Content-Length` header back out of its own captures and truncates the
body to size. This is the general pattern for anywhere a grammar's shape
alone underspecifies the language: let the grammar overmatch, then let
an action fix it up with information only available after parsing.

## Regex — a grammar that targets `Grammar.IR`, not a value

Parses the `/pattern/` dialect described in the
[Aether reference](aether/AETHER.md#regex-literals) — the same
shorthand token bodies can use — but as a *standalone* grammar whose
Actions module's target category is `Grammar.IR` itself, not a plain
Elixir value:

```text
@grammar "regex"
@root pattern
@noskip

pattern := alternative (PIPE alternative)*
atom    := group | char_class | DOT | SHORTHAND_CLASS | ESCAPED_CHAR | LITERAL_CHAR
```

`Regex.Actions` turns a parsed pattern into a real `Grammar.IR` tree —
`"\d+(\.\d+)?"` produces structurally the same `Grammar.IR` that
`Aether.Parser`'s own `/pattern/` desugaring builds for a token body
using that same literal. This is also exactly the technique every format
importer (`Ichor.ABNF`, `Ichor.BNF`, `Ichor.EBNF.ISO`, `Ichor.EBNF.W3C`,
`Ichor.PEG`) uses: an ordinary Aether grammar, describing another
format's syntax, paired with an Actions module whose "value" happens to
be `Grammar.IR` instead of a number or a map.

## Forth — a flat, non-tree-shaped language

```text
@grammar "forth"
@root program

program    := form*
form       := definition | NUMBER | WORD_NAME
definition := COLON WORD_NAME form* SEMI
```

Forth's own postfix, stack-based execution model doesn't nest the way
arithmetic expressions or LISP forms do — evaluating `form*` in order and
threading a stack through `context` is enough; `Forth.Actions` is a
small stack machine, proof that `Ichor.Actions`'s context-threading
handles a flat language just as well as a deeply nested one.

## Markdown — transpiling, not evaluating

```text
@grammar "markdown"
@root document
@noskip

block   := heading | list | paragraph
inline  := segment*
segment := bold | link | plain
```

Not every grammar's "value" is data — `Markdown.Actions` transpiles
bottom-up straight to an HTML string, `bold`'s handler wrapping its
inline content in `<strong>...</strong>`, `link` producing an `<a
href="...">`, and so on. The same `handle_rule`/`handle_token`/default-
fallback mechanism that evaluates a calculator expression or builds a
LISP closure works equally well for generating output text instead of a
data value — the category `Ichor.Actions` targets is entirely up to your
own module.

## Prolog — a grammar mutated mid-file, evaluated by a real logic engine

Real Prolog syntax — facts, rules with conjunction, and `:- op(...).`
directives — parsed by a grammar whose own operator table doesn't exist
until the source declares it, feeding an actual unification/backtracking
engine once parsed:

```text
@grammar "prolog"
@root clause
@skip WS

clause    := (directive | rule | fact) DOT
directive := RULE_OP goal:term
rule      := head:compound_or_atom RULE_OP body:conjunction
fact      := compound_or_atom

term := @native("Prolog.Grammar", "parse_term", primary) @hint(nullable: false, leading: (primary))
```

`term` is where this earns its place here: no fixed PEG/LR/GLR grammar
can express "parse an expression using whichever operators, at whichever
precedences, have been declared *so far*" — Prolog's own `op/3` can add
a brand new operator (or change an existing one's precedence) from
*inside* the file being parsed. `Prolog.Grammar.parse_term/4` (the
`@native(...)` callback) is built on `Ichor.Toolkit.Pratt`, driven
entirely by `context.operators` — and `Prolog.Actions`' own handling of
a `:- op(Prec, Type, Name).` directive returns an *updated* context with
the new operator added, which `Grammar.VM.run_sequence/4`'s per-form
context threading then hands to the *next* clause's own parse. Run
this file:

```prolog
:- op(200, xfy, ^).

father(tom, bob).
father(bob, ann).
grandparent(X, Z) :- father(X, Y), father(Y, Z).
power(N) :- N is 2 ^ 8.
```

and the `^` operator the last clause uses genuinely didn't exist until
the first line ran — remove the directive and `power`'s own clause fails
to parse, with the *same* grammar and the *same* source file otherwise
unchanged.

Parsing is only half of it: `Prolog.Actions` turns each fact/rule into
`{:compound, functor, args}`/`{:var, ref}` data (freshening each
clause's own variables consistently via `Ichor.Toolkit.TermWalk` — the
same name means the same variable *within* one clause, never across
two), which then unifies directly through `Ichor.Backtrack.Bindings` —
the exact same substrate the library's own SLD-resolution worked example
(`Ichor.Backtrack`) proves against hand-built terms, now fed by a real
parser instead of Elixir data literals:

```elixir
{:ok, [father_tom_bob], _ctx} = Grammar.VM.run_sequence(grammar, "father(tom, bob).", Prolog.Actions, Prolog.Actions.new_context())

query = {:compound, :father, [:tom, {:var, make_ref()}]}
{:ok, bindings} = Ichor.Backtrack.Bindings.unify(Prolog.Terms, Ichor.Backtrack.Bindings.new(), father_tom_bob, query)
```

See `test/prolog/` for the full grammar, actions, and test suite —
including the directive-genuinely-changes-parsing test above, run both
with and without the `op/3` line present.

## Running any of these three different ways

Every grammar above is shown as plain `.aether` source, but that's
independent of *how* it ends up running — see the
[tutorial](TUTORIAL.md#which-path-is-right-for-you) for the full
three-way breakdown. Two extremes worth calling out here specifically:

- **Ahead of time, via `mix ichor.gen`** (recommended): every grammar
  above works identically through it as it does through `use Ichor` —
  Prolog's own `@native(...)` rule included, since
  `Ichor.Toolkit.Pratt`/`Ichor.Toolkit.TermWalk`/`Ichor.Backtrack` (the
  pieces `Prolog.Grammar.parse_term/4` and `Prolog.Actions` are built
  on) live in the independently-published
  [`ichor_runtime`](https://hex.pm/packages/ichor_runtime), not `ichor`
  — a pregenerated Prolog parser still has everything its own
  `@native(...)` callback needs at runtime. See the
  [tutorial](TUTORIAL.md#9-shipping-a-compiled-parser-mix-ichor-gen-and-ichor_runtime)
  (§9, "Shipping a compiled parser") and the [cheatsheet](CHEATSHEET.md)
  ("Compile a grammar ahead of time") for the actual command and the
  resulting `mix.exs` shape.
- **Loaded at runtime, with no codegen at all**: any of these grammars
  could equally be text your program only sees once it's already
  running — a user-supplied LogQL filter, a Prolog knowledge base loaded
  from disk — via `Aether.Parser.parse` + `Grammar.Analysis.run` +
  `Grammar.VM`, exactly as shown in the
  [tutorial's runtime-loading section](TUTORIAL.md#8-loading-a-grammar-at-runtime)
  (§8). Right when "which grammar" is itself a runtime decision, not a
  build-time one.
