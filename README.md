# Ichor

Ichor compiles grammar definitions into working language implementations.
Write a grammar once — in Aether (Ichor's own grammar language) or import
one from ABNF, BNF, EBNF, or PEG — and Ichor turns it into a Lexer, a
Parser, and (via your own `Ichor.Actions` module) an Executor, with no
hand-written parsing code at all.

```elixir
defmodule Calculator do
  use Ichor, grammar_source: """
  @grammar "calculator"
  @root expr
  @skip SPACE

  NUMBER := DIGIT+ ("." DIGIT+)?

  expr   := term (op:("+" | "-") term)*
  term   := factor (op:("*" | "/") factor)*
  factor := NUMBER | "(" expr ")"
  """, actions: Calculator.Actions
end

Calculator.run("2 + 3 * 4")
#=> {:ok, 14}
```

`Calculator.Actions` is a plain module implementing the `Ichor.Actions`
behaviour — it decides what each rule and token *means*; the grammar
only decides what's valid *syntax*. See the [tutorial](guides/TUTORIAL.md)
for the full walkthrough of this example, including the Actions module.

## Why

Most grammar tools stop at "does this text match" (a recognizer) or "here's
a parse tree, good luck" (a parser generator). Ichor goes one step further:
every grammar pairs with an `Ichor.Actions` module that says what to *do*
with each piece of a match — evaluate it, build a config struct, execute a
query, transpile it, whatever the grammar is for. The same grammar, parsed
by either of two independent backends, always produces identical results
through that same Actions module.

## How it fits together

```text
  .aether source                     ABNF / BNF / EBNF / PEG source
        │                                        │
        ▼                                        ▼
  Aether.Lexer + Aether.Parser         Ichor.ABNF / .BNF / .EBNF.* / .PEG
        │                                        │
        └───────────────┬────────────────────────┘
                         ▼
                  Grammar.IR (+ Grammar.Analysis)
                         │
           ┌─────────────┴─────────────┐
           ▼                           ▼
     Grammar.VM                  Grammar.Native
  (bytecode interpreter)      (compile-time codegen,
                                `use Ichor`)
           │                           │
           └─────────────┬─────────────┘
                         ▼
                  Ichor.Actions
        (your module: evaluate, build, execute, transpile...)
```

Every Aether grammar compiles to a genuine two-stage **Lexer -> Parser**,
never a single scannerless pass: tokens (`ALL_CAPS` names) are matched
by *maximal munch* over raw characters — longest match wins, ties
broken by declaration order — producing a token stream; rules
(`snake-case` names) then run over that stream as an ordered-choice
(PEG-style) parser, first alternative to match wins. This split is
structural, not an implementation detail — it's what lets both backends
agree byte-for-byte on what a grammar means.

## Components

- **[Aether](guides/aether/AETHER.md)** — Ichor's own grammar language.
  Tokens vs. rules, `@skip`/`@noskip` whitespace handling,
  `@indent`/`@samecol` for layout-sensitive languages, POSIX character
  classes, and a `/pattern/` regex-literal shorthand for token bodies.
  See `Aether.Lexer` and `Aether.Parser`.
- **`Grammar.IR`** — the normalized AST every front-end compiles to and
  every backend consumes: 14 node types (`Seq`, `Choice`, `Star`, `Plus`,
  `Opt`, `Rep`, `AndPred`, `NotPred`, `Literal`, `CharClass`, `Any`,
  `RuleRef`, `Indent`, `Capture`), each carrying source-location metadata.
- **`Grammar.Analysis`** — reference checks, a direct-left-recursion
  rewrite (`A := A op b | base` becomes the iterative `A := base (op b)*`),
  an empty-repetition hazard check, and a duplicate-alternative lint.
- **`Grammar.VM`** — an interpreted backend: compiles a grammar to
  LPeg-style bytecode and runs it against real input. No compilation
  step beyond building the bytecode itself — good for grammars loaded
  at runtime.
- **`Grammar.Native`** — a compile-time backend: `use Ichor,
  grammar: ..., actions: ...` splices generated Elixir functions
  straight into your module, skipping bytecode interpretation entirely.
  Roughly 2x the VM backend's speed, at the cost of needing the grammar
  at compile time.
- **`Ichor.Actions`** — the behaviour connecting a parsed grammar to real
  behavior: `handle_rule/3`, `handle_token/3`, and an optional
  `finalize/1`, with a sensible default fallback for rules/tokens that
  need no custom handling.
- **Format importers** — `Ichor.ABNF` (RFC 5234 + RFC 7405), `Ichor.BNF`
  (classical, ALGOL 60 Report convention), `Ichor.EBNF.ISO` (ISO/IEC
  14977), `Ichor.EBNF.W3C` (the notation the XML 1.0 spec's own
  section 6 uses), and `Ichor.PEG` (Ford's paper / pest / PEG.js
  convention). Each turns its own dialect into the same `Grammar.IR`
  shape every other front-end produces.
- **`mix ichor.tokens`** — lists every token a grammar declares, in the
  exact order the lexer's maximal-munch tie-break uses, with a rendered
  pattern for each.

## Installation

Ichor isn't published on Hex yet. Until then, depend on it directly from
its source:

```elixir
def deps do
  [
    {:ichor, path: "path/to/ichor"}
    # or: {:ichor, github: "your-org/ichor"}
  ]
end
```

Once published, the usual form will apply:

```elixir
def deps do
  [
    {:ichor, "~> 0.1.0"}
  ]
end
```

## Where to go next

- **[Tutorial](guides/TUTORIAL.md)** — a step-by-step walkthrough of
  Ichor's features, building up to a complete, working calculator.
- **[Examples](guides/EXAMPLES.md)** — worked examples across a range of
  language shapes: a LISP dialect, YAML, a log-query language, SQL,
  HTTP, regex, Forth, and a Markdown-to-HTML transpiler.
- **[Cheatsheet](guides/CHEATSHEET.md)** — quick reference for common
  Ichor tasks.
- **[Aether tutorial](guides/aether/TUTORIAL.md)** and
  **[Aether reference](guides/aether/AETHER.md)** — everything about the
  grammar language itself, independent of the surrounding library.

## Development

```sh
mix deps.get
mix test
mix format --check-formatted
mix compile --warnings-as-errors
mix docs
```

See [CONTRIBUTION.md](CONTRIBUTION.md) for how to propose changes, and
[CHANGELOG.md](CHANGELOG.md) for release history.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
