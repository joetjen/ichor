# Ichor

[![Hex.pm](https://img.shields.io/hexpm/v/ichor.svg)](https://hex.pm/packages/ichor)
[![Documentation](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ichor)

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

The inline `use Ichor` form above is the fastest way to try Ichor out —
for anything beyond that, prefer `mix ichor.gen` (below): it's the same
codegen, run once ahead of time instead of on every compile.

## Why

Most grammar tools stop at "does this text match" (a recognizer) or "here's
a parse tree, good luck" (a parser generator). Ichor goes one step further:
every grammar pairs with an `Ichor.Actions` module that says what to *do*
with each piece of a match — evaluate it, build a config struct, execute a
query, transpile it, whatever the grammar is for. The same grammar, parsed
by either of two independent backends, always produces identical results
through that same Actions module.

## Three ways to run a grammar

A grammar's `Ichor.Actions` module is the same no matter how the grammar
itself gets turned into a parser — but *when* that happens is a real
choice, with a real consequence for what your app depends on at
runtime:

| Path | When codegen runs | `ichor` needed at runtime? | Best for |
| --- | --- | --- | --- |
| **`mix ichor.gen`** (recommended) | Once, ahead of time, from the command line | No — `ichor_runtime` only | Anything shipping to production |
| **`use Ichor`** | Every `mix compile` | Yes | A grammar that's still actively changing |
| **Raw pipeline** (`Aether.Parser` + `Grammar.Analysis` + `Grammar.VM`) | At your program's own runtime | Yes | A grammar not known until runtime (user-supplied, plugins, a REPL) |

The reason `mix ichor.gen` is the recommended default is concrete, not
stylistic: a module using `use Ichor` needs the real `Ichor` module —
and so the whole `ichor` package — present *at compile time, in
whatever environment you compile in*, including a `mix release` build
(which normally compiles under `MIX_ENV=prod`). That means `ichor`
can't be marked `only: :dev, runtime: false` in any app that still has
so much as one `use Ichor` module in its tree; Mix won't even load the
`Ichor` module under `:prod` to expand the macro, so compilation fails
outright. `mix ichor.gen`-generated code has no macro dependency on
`ichor` at all — just ordinary function calls into `ichor_runtime` — so
it's the only one of the three that actually lets `ichor` be dev-only.
See the [tutorial](guides/TUTORIAL.md) for a full worked example of all
three (§7-9), or the [cheatsheet](guides/CHEATSHEET.md) for a quick
reference once you know which one you want.

## How it fits together

```text
  .aether source                     ABNF / BNF / EBNF / PEG source
        │                                        │
        ▼                                        ▼
  Aether.Reader + Aether.Eval          Ichor.ABNF / .BNF / .EBNF.* / .PEG
        │                                        │
        └───────────────┬────────────────────────┘
                         ▼
                  Grammar.IR (+ Grammar.Analysis)
                         │
              @engine peg | lr | glr
                         │
           ┌─────────────┴─────────────┐
           ▼                           ▼
       Grammar.VM                Grammar.Native
  (bytecode interpreter,     (compile-time codegen,
   PEG / LR / GLR engines)    PEG / LR / GLR engines)
           │                           │
           └─────────────┬─────────────┘
                         ▼
                  Ichor.Actions
        (your module: evaluate, build, execute, transpile...)
```

Every Aether grammar compiles to a genuine multi-stage pipeline, never a
single scannerless pass: tokens (`ALL_CAPS` names) are matched by
*maximal munch* over raw characters — longest match wins, ties broken by
declaration order — producing a token stream, optionally reclassified
by `@keywords`/`@refine` (e.g. distinguishing a keyword from an
ordinary identifier, or JavaScript's regex-literal-vs-division
ambiguity); rules (`snake-case` names) then run over that stream as an
ordered-choice (PEG-style, the default) parser, or — for a grammar
tagged `@engine lr`/`@engine glr` — a deterministic shift-reduce or
genuine Tomita-style GLR parser instead, for CFG shapes plain PEG can't
express (left recursion, genuine ambiguity). This split is structural,
not an implementation detail — it's what lets every backend/engine
combination agree byte-for-byte on what a grammar means. A rule or token
can also opt out of all of this entirely via `@native(...)`, dispatching
to your own Elixir callback for the rare case a grammar's meaning is
mutated mid-file by something declared earlier (Prolog's `op/3`,
heredocs, string interpolation).

## Components

- **[Aether](guides/aether/AETHER.md)** — Ichor's own grammar language.
  Tokens vs. rules, `@skip`/`@noskip` whitespace handling,
  `@indent`/`@samecol` for layout-sensitive languages, POSIX character
  classes, a `/pattern/` regex-literal shorthand for token bodies,
  `@keywords`/`@refine` for post-tokenization reclassification,
  `@engine peg | lr | glr` to pick the parsing algorithm, and
  `@native(...)`/`@hint(...)` as an escape hatch at rule or token
  position for grammars mutated mid-file (runtime-mutable operator
  precedence, heredocs, string interpolation). See `Aether.Reader` and
  `Aether.Eval`.
- **`Grammar.IR`** — the normalized AST every front-end compiles to and
  every backend consumes: 16 node types (`Seq`, `Choice`, `Star`, `Plus`,
  `Opt`, `Rep`, `AndPred`, `NotPred`, `Literal`, `CharClass`, `Any`,
  `RuleRef`, `Indent`, `Capture`, `Custom`, `CustomLexeme`), each
  carrying source-location metadata.
- **`Grammar.Analysis`** — reference checks, a direct-left-recursion
  rewrite for `@engine peg` grammars (`A := A op b | base` becomes the
  iterative `A := base (op b)*`; skipped for `lr`/`glr`, which want left
  recursion, not a rewrite of it), an empty-repetition hazard check, and
  a duplicate-alternative lint.
- **`Grammar.VM`** — an interpreted backend: compiles a grammar to
  LPeg-style bytecode (PEG) or builds an SLR(1) table (`lr`/`glr`) and
  runs it against real input. No compilation step beyond that — good for
  grammars loaded at runtime. `Grammar.LR`/`Grammar.GLR` are the
  standalone LR/GLR engines this dispatches to.
- **`Grammar.Native`** — a compile-time backend: `use Ichor,
  grammar: ..., actions: ...` splices generated Elixir functions
  straight into your module for whichever `@engine` the grammar
  declares, skipping bytecode/table interpretation entirely — an
  `@engine lr` grammar compiles to one Elixir function per automaton
  state, a genuine Bison-style compiled parser.
- **`Ichor.Actions`** — the behaviour connecting a parsed grammar to real
  behavior: `handle_rule/3`, `handle_token/3`, and an optional
  `finalize/1`, with a sensible default fallback for rules/tokens that
  need no custom handling.
- **`Ichor.Backtrack`** — a generic lazy-search-plus-unification
  substrate for logic-language evaluation models (SLD-resolution and
  friends): `Ichor.Backtrack.Tree`'s lazy, depth-first `disjunction`/
  `conjunction`/`once` combinators, and `Ichor.Backtrack.Bindings`'
  substitution/unification over any term representation you supply.
  Opt-in — nothing in Ichor's core ever calls it.
- **`Ichor.Toolkit`** — small, IR-agnostic building blocks for a grammar
  author's own downstream semantic analysis, type inference, or codegen
  (`Fixpoint`, `Graph`, `Scope`, `TypeScheme`, `Codegen`, `Result`,
  `Pratt`, `Layout`, `TermWalk`) — extracted from patterns Ichor's own
  compiler internals had already hand-rolled more than once. Also
  opt-in; see each module's own docs.
- **Format importers** — `Ichor.ABNF` (RFC 5234 + RFC 7405), `Ichor.BNF`
  (classical, ALGOL 60 Report convention), `Ichor.EBNF.ISO` (ISO/IEC
  14977), `Ichor.EBNF.W3C` (the notation the XML 1.0 spec's own
  section 6 uses), and `Ichor.PEG` (Ford's paper / pest / PEG.js
  convention). Each turns its own dialect into the same `Grammar.IR`
  shape every other front-end produces.
- **`mix ichor.tokens`** — lists every token a grammar declares, in the
  exact order the lexer's maximal-munch tie-break uses, with a rendered
  pattern for each.
- **`mix ichor.gen`** — the recommended way to turn a grammar into a
  parser (see [Three ways to run a grammar](#three-ways-to-run-a-grammar)
  above): runs the same parse/analyze/codegen pipeline as `use Ichor`
  ahead of time, writing the result to a plain `.ex` file instead of
  splicing it into a macro expansion. Also accepts ABNF/BNF/ISO EBNF/PEG
  source directly (style picked from the file extension or an `@style`
  pragma), for reusing an existing non-Aether grammar without
  hand-translating it first.
- **[`ichor_runtime`](https://github.com/joetjen/ichor_runtime)** —
  independently published and maintained, the small support library
  every Ichor-generated parser calls into at runtime: capture dispatch
  (`Ichor.Actions`), error formatting (`Ichor.Error`), the compiled
  Tokenizer/Parser combinators, the LR/GLR shift-reduce/GSS runtime, and
  standalone `Ichor.Toolkit.Pratt`/`TermWalk`/`Ichor.Backtrack`. It's
  everything left over once you subtract "the compiler" from "what a
  generated parser actually calls" — which is exactly what lets a
  project depending on `mix ichor.gen` output alone mark `ichor` itself
  `only: :dev, runtime: false` (see
  [Three ways to run a grammar](#three-ways-to-run-a-grammar)). Ichor
  itself — grammar parsing, analysis, and both codegen backends —
  depends on it too (it's the one piece both the interpreted and
  compiled backends share), but never the other way around.

## Installation

**Recommended**: if every grammar you use is pregenerated ahead of time
(`mix ichor.gen`, never `use Ichor` at your app's own compile time),
add [`ichor_runtime`](https://hex.pm/packages/ichor_runtime) as your
real runtime dependency and keep `ichor` itself dev-only:

```elixir
def deps do
  [
    {:ichor_runtime, "~> 0.1.0"},
    {:ichor, "~> 0.2.0", only: :dev, runtime: false}
  ]
end
```

If you're still using `use Ichor` at your app's own compile time (a
grammar that's still actively changing, say), `ichor` has to be a real
dependency instead — it can't be `only: :dev` once anything in your app
still expands that macro:

```elixir
def deps do
  [
    {:ichor, "~> 0.2.0"}
  ]
end
```

## Where to go next

- **[Tutorial](guides/TUTORIAL.md)** — a step-by-step walkthrough of
  Ichor's features, building up to a complete, working calculator.
- **[Examples](guides/EXAMPLES.md)** — worked examples across a range of
  language shapes: a LISP dialect, YAML, a log-query language, SQL,
  HTTP, regex, Forth, a Markdown-to-HTML transpiler, and Prolog (real
  clause/`op/3` syntax feeding `Ichor.Backtrack`).
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

MIT — see [LICENSE](LICENSE).
