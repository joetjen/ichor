# Cheatsheet

Quick reference for common tasks. See the [tutorial](TUTORIAL.md) if
anything here doesn't make sense yet, or the
[Aether cheatsheet](aether/AETHER_CHEATSHEET.md) for grammar-syntax-level
lookups.

## Which one do I want?

| Path | `ichor` needed at runtime? | Best for |
| --- | --- | --- |
| **`mix ichor.gen`** (recommended) | No — `ichor_runtime` only | Anything shipping to production |
| **`use Ichor`** (native backend) | Yes | A grammar that's still actively changing |
| **`Grammar.VM`** (no compile step) | Yes | A grammar not known until runtime |

See the [tutorial](TUTORIAL.md#which-path-is-right-for-you) for the full
reasoning behind the `ichor`-at-runtime column.

## Parse a grammar

```elixir
{:ok, grammar} = Aether.Parser.parse(source, file \\ nil)
{:ok, grammar} = Grammar.Analysis.run(grammar)
```

Always run a grammar through `Grammar.Analysis` before matching it —
it rewrites direct left recursion and rejects hazards (dangling
references, unreachable duplicate alternatives, repetitions that can
never terminate) before they become runtime bugs. Only needed if you're
parsing a grammar yourself (the `Grammar.VM` path below, or writing your
own tooling) — `use Ichor` and `mix ichor.gen` already do this for you.

## Compile a grammar ahead of time (`mix ichor.gen`)

```sh
mix ichor.gen PATH_TO_GRAMMAR --module MODULE --actions ACTIONS_MODULE --out PATH
```

Same pipeline as `use Ichor`, run once from the command line instead of
inside a macro expansion on every compile — writes a plain, ordinary
`MODULE` to `PATH`, with the exact same `tokenize/1`/`parse/1`/`run/1,2`
functions `use Ichor` would generate. Rerun by hand whenever the grammar
changes; no automatic staleness check.

`PATH_TO_GRAMMAR` doesn't have to be `.aether` source — ABNF, BNF, ISO
EBNF, and PEG grammars work too (via `Ichor.GrammarImport`), the style
picked automatically from the extension, or overridden with an
`@style` line in the source (`@style abnf`, `@style bnf`, `@style
ebnf`, `@style peg`, `@style aether`):

| Extension | Style |
| --- | --- |
| `.aether` (default) | Aether |
| `.abnf` | ABNF (RFC 5234 + RFC 7405) |
| `.bnf` | Classical BNF |
| `.ebnf` | ISO EBNF (ISO/IEC 14977) |
| `.peg` | PEG |

For a non-Aether style, the entry rule is the source's own
first-declared rule unless overridden with `--root NAME`, the grammar
is always `@noskip`, and ABNF's RFC 5234 Appendix B "core rules"
(`ALPHA`, `DIGIT`, `CRLF`, ...) are filled in automatically for
whatever the source references but never defines.

The generated file only ever calls into
[`ichor_runtime`](https://hex.pm/packages/ichor_runtime) — an
independently published package, never `ichor` itself — so a project
using only pregenerated parsers can mark `ichor` `only: :dev,
runtime: false` and depend on `ichor_runtime` as its one normal runtime
dependency:

```elixir
def deps do
  [
    {:ichor_runtime, "~> 0.2"},
    {:ichor, "~> 0.2.0", only: :dev, runtime: false}
  ]
end
```

## Compile a grammar at build time (native backend)

```elixir
defmodule MyLang do
  use Ichor, grammar: "my_lang.aether", actions: MyLang.Actions
  # or: use Ichor, grammar_source: "...", actions: MyLang.Actions
end

MyLang.tokenize(input)  #=> {:ok, [%Grammar.VM.Token{}]} | {:error, error}
MyLang.parse(input)     #=> {:ok, pos, raw_captures} | {:error, error}
MyLang.run(input, ctx \\ nil)
MyLang.run_sequence(input, ctx)
```

`grammar:` resolves relative to the `use`-ing module's own file.
Exactly one of `grammar:` / `grammar_source:` is required. Unlike
`mix ichor.gen`, this re-parses/re-analyzes/re-generates the grammar on
every `mix compile` — and needs `ichor` present wherever that compile
happens, `mix release` builds included, so `ichor` can't be `only: :dev`
here.

## Match with the VM backend (no compile step)

```elixir
Grammar.VM.parse(grammar, input)
#=> {:ok, tokens_consumed} | {:error, %Ichor.Error{}}

Grammar.VM.run(grammar, input, MyActions, initial_context \\ nil)
#=> {:ok, value} | {:error, error_or_errors}

Grammar.VM.run_sequence(grammar, input, MyActions, initial_context)
#=> {:ok, [values], final_context} | {:error, error_or_errors}
```

Use `run_sequence/4` when `input` is several top-level forms back to
back (e.g. a source file of many top-level definitions), not one single
match spanning the whole string. This is the path for a grammar loaded
at runtime — see the [tutorial](TUTORIAL.md#8-loading-a-grammar-at-runtime)
for a worked example.

## Match an `@engine lr`/`@engine glr` grammar

`Grammar.VM` only ever runs `@engine peg` grammars (a clear error for
anything else) — use the standalone engines directly instead,
interpreted:

```elixir
Grammar.LR.compile(grammar)
#=> {:ok, table} | {:error, [errors]}  -- errors if the table has any conflict at all

Grammar.LR.run(grammar, input, MyActions, initial_context \\ nil)
Grammar.GLR.run(grammar, input, MyActions, initial_context \\ nil)
#=> same shape as Grammar.VM.run/4; GLR accepts conflicts and forks instead of rejecting them
```

`use Ichor` (the compile-time/native backend, above) dispatches
automatically based on the grammar's own `@engine` — `MyLang.run/1,2`
works identically no matter which engine the grammar declares; nothing
in your own calling code changes.

## Write an `Ichor.Actions` module

```elixir
defmodule MyLang.Actions do
  @behaviour Ichor.Actions

  @impl true
  def handle_token(:NUMBER, text, _ctx), do: {:ok, String.to_integer(text)}

  @impl true
  def handle_rule(:add, %{left: l, right: r}, ctx) do
    {:ok, lv, ctx} = l.eval.(ctx)
    {:ok, rv, ctx} = r.eval.(ctx)
    {:ok, lv + rv, ctx}
  end

  # optional: runs once, after everything else
  @impl true
  def finalize(ctx), do: :ok
end
```

- Implement only the rules/tokens that need custom behavior — everything
  else falls back automatically.
- **Default fallback for a rule**: exactly one meaningful capture passes
  its value straight through; more than one builds an `%Ichor.Node{rule:
  ..., captures: %{...}}`.
- **Default fallback for a token**: the raw matched text, unchanged.
- A capture under `*`/`+`/`{n,m}` always arrives as a **list**, even if
  it matched zero or one times — never a bare value, never a missing key.
- `cap.node` is the raw, unevaluated parse; `cap.eval.(ctx)` evaluates it
  and returns `{:ok, value, new_ctx}` — call `eval` only when you
  actually want the value, which is what lets `if`/`quote`-style special
  forms skip evaluating a branch entirely.

## Import another grammar format

```elixir
{:ok, ruleset} = Ichor.ABNF.run(abnf_source)       # RFC 5234 + RFC 7405
{:ok, ruleset} = Ichor.BNF.run(bnf_source)          # classical BNF
{:ok, ruleset} = Ichor.EBNF.ISO.run(ebnf_source)    # ISO/IEC 14977
{:ok, ruleset} = Ichor.EBNF.W3C.run(ebnf_source)    # XML 1.0 spec's own notation
{:ok, ruleset} = Ichor.PEG.run(peg_source)          # Ford/pest/PEG.js convention
```

Every importer returns `{:ok, %{rule_name_atom => Grammar.IR.expr()}}` —
`Grammar.IR`, the same target category `Regex.Actions` and every other
grammar-to-IR Actions module produces, not a runnable `Aether.Grammar`.
ABNF note: source must use literal `\r\n` line endings per RFC 5234 —
normalize before parsing if your source uses `\n` only.

## `Ichor.Backtrack`: logic-language evaluation (Prolog-style SLD-resolution)

Opt-in — nothing in Ichor's own core ever calls this; it's a substrate
for your own grammar's evaluation model, e.g. an `Ichor.Actions` module
whose `context` threads a clause database.

```elixir
defmodule MyTerms do
  @behaviour Ichor.Backtrack.Term

  def variable?({:var, _id}), do: true
  def variable?(_), do: false
  def var_id({:var, id}), do: id
  def compound?({:compound, _f, _args}), do: true
  def compound?(_), do: false
  def deconstruct({:compound, f, args}), do: {f, args}
  # optional -- only needed if you ever rebuild a term (substitution):
  def reconstruct(f, args), do: {:compound, f, args}
end

alias Ichor.Backtrack.{Tree, Bindings}

Bindings.unify(MyTerms, Bindings.new(), t1, t2)
#=> {:ok, bindings} | :fail
Bindings.unify_occurs_check(MyTerms, bindings, t1, t2)
#=> like unify/4, but rejects an infinite term (`X = f(X)`) instead of
#   silently building one -- ISO Prolog's own unify/2 doesn't do this
#   by default; a type checker generally should

goal = Tree.conjunction(goal1, goal2)  # also: Tree.disjunction/2, Tree.once/1, Tree.unit/0, Tree.fail/0
Tree.next(goal.(Bindings.new()))
#=> {:solution, bindings, more_solutions} | :empty  -- pulled lazily, one at a time
```

## `Ichor.Toolkit`: reusable building blocks for your own downstream passes

Also opt-in — small, IR-agnostic modules for whatever a grammar author
does with a parsed result (semantic analysis, type inference, codegen),
extracted from patterns Ichor's own compiler had already hand-rolled
more than once. None of them run automatically.

- **`Fixpoint`** — `least/2`, iterate a step function to convergence
- **`Graph`** — `reachable/2`, reachability/cycle detection over an arbitrary graph
- **`Scope`** — a generic nested lexical scope/symbol table
- **`TypeScheme`** — Hindley-Milner let-polymorphism (`generalize`/`instantiate`/`resolve_deep`)
- **`Codegen`** — `quote`/`unquote` mechanics for hand-writing your own codegen backend
- **`Result`** — `reduce_ok`/`map_ok`, `Enum.reduce` with early exit on failure
- **`Pratt`** — precedence-climbing (prefix/infix/postfix) expression parsing
- **`Layout`** — the Python/Haskell/F#-style off-side-rule `INDENT`/`DEDENT` algorithm
- **`TermWalk`** — generic `fold`/`rewrite` recursion over any `Ichor.Backtrack.Term`

## Inspect a grammar's tokens

```sh
mix ichor.tokens path/to/grammar.aether
```

Lists every token — declared, anonymous (auto-promoted from an inline
literal), and the five predefined ones — in the exact order the lexer's
maximal-munch tie-break uses, with a rendered pattern for each.

## Common pragmas, at a glance

- **`@grammar "name"`** — required; names the grammar
- **`@root rule_name`** — required; where matching starts
- **`@engine peg | lr | glr`** — the parsing algorithm (default `peg`)
- **`@skip TOKEN`** — auto-splice `TOKEN*` between sequence elements (default: `SPACE`)
- **`@noskip`** — disable auto-splicing entirely — whitespace is meaningful
- **`@case_insensitive`** — every bare quoted literal matches either case
- **`@indent(expr)`** — `expr` must start at a column deeper than the enclosing block
- **`@samecol expr`** — `expr` must start at exactly the enclosing block's own column
- **`@keywords TOKEN { "lit" -> TARGET, ... }`** — reclassify a matched token by its own text
- **`@refine("Module", "fun", ...)`** — reclassify a token via a callback (needs lookbehind, decoding, ...)
- **`@native("Module", "fun", dep, ...)` / `@hint(...)`** — hand a rule or token to your own Elixir callback

See the [Aether reference](aether/AETHER.md) for the full list and every
operator.
