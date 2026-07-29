# Ichor Tutorial

This tutorial builds a small arithmetic calculator from nothing, introducing
each piece of Ichor as it becomes necessary. By the end you'll have a
working `Calculator` module that evaluates `"2 + 3 * 4"` to `14`, and
you'll understand every layer between the grammar text and that result.

If you want a deep dive into Aether's own syntax (tokens, rules, every
pragma, every operator), see the [Aether tutorial](aether/TUTORIAL.md) and
[Aether reference](aether/AETHER.md) instead — this tutorial only
introduces as much Aether as the calculator example needs.

## 1. A grammar is just a string

Aether grammars are plain text, parsed by `Aether.Parser`. Every grammar
needs exactly two things: a `@grammar` name and a `@root` rule (the rule
matching must start from). Let's start with the smallest possible
grammar — one that recognizes a single digit:

```elixir
{:ok, grammar} = Aether.Parser.parse("""
@grammar "digit"
@root digit

digit := "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"
""")
```

`Aether.Parser.parse/1` returns `{:ok, %Aether.Grammar{}}` or
`{:error, %Ichor.Error{}}`. `%Aether.Grammar{}` isn't runnable by itself
yet — it's the compiled AST, ready to be handed to the analysis pass and
then a backend.

## 2. Analysis, then a backend

Every grammar should go through `Grammar.Analysis` before it's matched
against real input — it catches dangling references, unreachable
alternatives, and a repetition that can never terminate:

```elixir
{:ok, grammar} = Grammar.Analysis.run(grammar)
```

Now it can be matched. `Grammar.VM` is the interpreted backend — no
compile-time setup, good for a grammar loaded at runtime:

```elixir
Grammar.VM.parse(grammar, "7")
#=> {:ok, 1}

Grammar.VM.parse(grammar, "x")
#=> {:error, %Ichor.Error{...}}
```

`parse/2` is a bare recognizer: it tells you whether the whole input
matches the root rule (returning how many tokens were consumed), nothing
more. There's no evaluation yet, because we haven't told Ichor what a
match should *mean*.

## 3. Tokens vs. rules

Aether has exactly one syntactic rule that decides whether something is a
**token** or a **rule**: `ALL_CAPS` names are tokens, `snake-case` names
are rules. Tokens are matched by the *lexer*, over raw characters, using
**maximal munch** — the longest match wins, ties broken by declaration
order. Rules are matched by the *parser*, over the resulting token
stream, using ordered PEG choice — first alternative to match wins,
always.

This split is why the digit grammar above works even though `digit` looks
token-like in spirit: its alternatives are all bare literals, so Aether
still treats `digit` as a rule (lowercase name), and each quoted string
inside it becomes an anonymous, compiler-generated token automatically.
You never have to declare a token for every literal by hand.

Let's write NUMBER as a real, explicit token instead, using a regex-literal
shorthand for token bodies (`/pattern/` — only valid inside a token,
desugars entirely to ordinary Aether primitives, not a real regex engine):

```text
NUMBER := /\d+(\.\d+)?/
```

## 4. Whitespace: `@skip`

Real input has whitespace between tokens. Aether grammars skip it
automatically by default — every rule's sequence elements get a
`SPACE*` spliced in between them — so you don't have to write whitespace
tolerance into every rule by hand. This can be pointed at a different
token (`@skip TRIVIA`, useful when comments should also be skipped) or
turned off entirely (`@noskip`, needed for grammars like regex or HTTP
where whitespace is meaningful). Leaving it unstated, as we've done so
far, uses the built-in `SPACE` token.

## 5. The full calculator grammar

Putting the pieces together — tokens for `NUMBER`, rules for standard
arithmetic precedence, and named captures (`name:expr`) so an
`Ichor.Actions` module can tell the operator apart from the operands:

```elixir
grammar_text = """
@grammar "calculator"
@root expr

NUMBER := /\\d+(\\.\\d+)?/

expr   := term (op:("+" | "-") term)*
term   := factor (op:("*" | "/") factor)*
factor := NUMBER | "(" expr ")"
"""

{:ok, grammar} = Aether.Parser.parse(grammar_text)
{:ok, grammar} = Grammar.Analysis.run(grammar)

Grammar.VM.parse(grammar, "2 + 3 * 4")
#=> {:ok, 9}   # 9 tokens consumed -- SPACE is a real token in the
               # stream too, just one the parser skips automatically
```

It recognizes the input — but `parse/2` only tells us it's valid, not
what it evaluates to. That's `Ichor.Actions`'s job.

## 6. Giving meaning: `Ichor.Actions`

An `Ichor.Actions` module implements up to three callbacks:

- `handle_token/3` — turn a token's raw text into a value.
- `handle_rule/3` — combine a rule's already-evaluated captures into
  its own value.
- `finalize/1` (optional) — run once, over whatever context evaluation
  produced.

Anything a grammar doesn't implement falls back to sensible defaults: a
rule with exactly one meaningful capture passes that capture's value
straight through; anything else builds an `Ichor.Node`.

```elixir
defmodule Calculator.Actions do
  @behaviour Ichor.Actions

  @impl true
  def handle_token(:NUMBER, text, _ctx) do
    value = if String.contains?(text, "."), do: String.to_float(text), else: String.to_integer(text)
    {:ok, value}
  end

  @impl true
  def handle_rule(:expr, %{op: ops, term: terms}, ctx), do: fold(terms, ops, ctx)
  def handle_rule(:term, %{op: ops, factor: factors}, ctx), do: fold(factors, ops, ctx)

  defp fold([first | rest], ops, ctx) do
    {:ok, first_val, ctx} = first.eval.(ctx)

    Enum.zip(ops, rest)
    |> Enum.reduce({:ok, first_val, ctx}, fn {op, term}, {:ok, acc, ctx} ->
      {:ok, op_val, ctx} = op.eval.(ctx)
      {:ok, term_val, ctx} = term.eval.(ctx)
      {:ok, apply_op(op_val, acc, term_val), ctx}
    end)
  end

  defp apply_op("+", a, b), do: a + b
  defp apply_op("-", a, b), do: a - b
  defp apply_op("*", a, b), do: a * b
  defp apply_op("/", a, b), do: a / b
end
```

A few things worth noticing:

- `factor` needs **no clause at all** — `factor := NUMBER | "(" expr ")"`
  always has exactly one meaningful capture, so the default fallback
  already does the right thing (passes the matched `NUMBER` or nested
  `expr`'s value straight through).
- `terms`/`factors` are lists of `Ichor.Capture` structs, not plain
  values — each one bundles the raw parse (`.node`) with a callable
  (`.eval`) that evaluates it against a context you control. Nothing is
  evaluated until you call `.eval` on it yourself. This is what lets a
  grammar with real special forms (an `if`, a `quote`) choose *whether*
  and *when* to evaluate a branch at all — the calculator here doesn't
  need that power, but the mechanism is the same one that does.
- `op` and `term`/`factor` are captured under a `Star` (the `(...)*`),
  so they always arrive as lists — even an expression with no operators
  at all still gets `%{op: [], term: [single_capture]}`, never a missing
  key.

Now run the grammar through its Actions module:

```elixir
Grammar.VM.run(grammar, "2 + 3 * 4", Calculator.Actions)
#=> {:ok, 14}
```

## 7. Compiling for speed: the native backend

`Grammar.VM` interprets bytecode — simple, and good enough for most uses.
When the grammar is known at compile time, `Grammar.Native` (via
`use Ichor`) generates real Elixir functions instead, skipping bytecode
interpretation entirely:

```elixir
defmodule Calculator do
  use Ichor, grammar_source: """
  @grammar "calculator"
  @root expr

  NUMBER := /\\d+(\\.\\d+)?/

  expr   := term (op:("+" | "-") term)*
  term   := factor (op:("*" | "/") factor)*
  factor := NUMBER | "(" expr ")"
  """, actions: Calculator.Actions
end

Calculator.run("2 + 3 * 4")
#=> {:ok, 14}
```

`use Ichor` generates `tokenize/1`, `parse/1` (bare recognizer, no
actions), and `run/1,2` directly on `Calculator`, dispatching to
`Calculator.Actions` with the module reference baked in at compile
time — no dynamic module lookup at runtime. Use `grammar:` instead of
`grammar_source:` to load the grammar from a `.aether` file on disk,
resolved relative to the `use`-ing module's own source file:

```elixir
defmodule Calculator do
  use Ichor, grammar: "calculator.aether", actions: Calculator.Actions
end
```

Both backends implement identical semantics — the same grammar produces
the same result either way. Pick `Grammar.VM` for grammars loaded at
runtime (user-supplied config formats, a REPL that loads grammars on
demand) and `Grammar.Native` for grammars fixed at compile time, where
the extra speed is worth it.

## 8. Shipping a compiled parser: `mix ichor.gen` and `ichor_runtime`

`use Ichor` is convenient, but it means `Calculator`'s own `mix compile`
re-parses `calculator.aether`, re-runs `Grammar.Analysis`, and re-runs
the native codegen backend *every single time* — inside a macro
expansion, on every compile, forever. For a grammar that's stopped
changing, that's pure overhead: the codegen work only ever needs to
happen once.

`mix ichor.gen` runs that exact same parse → analyze → codegen pipeline
from the command line instead, writing the result to a plain, ordinary
`.ex` file you check in like any other source file:

```sh
mix ichor.gen calculator.aether \
    --module Calculator \
    --actions Calculator.Actions \
    --out lib/calculator.ex
```

Open `lib/calculator.ex` afterward — it's exactly the same `tokenize/1`,
`parse/1`, `run/1,2` functions `use Ichor` would have spliced in, just
generated once and committed instead of regenerated on every compile.
`Calculator.run("2 + 3 * 4")` still returns `{:ok, 14}`, identically.

This is more than a compile-time optimization, though — it changes what
your project needs installed *at all*. The generated file only ever
calls a small, fixed set of support modules by name (`Ichor.Actions`,
`Ichor.Error`, the compiled Tokenizer/Parser combinators, and — for an
`@engine lr`/`glr` grammar — the LR/GLR runtime). That set is exactly
what the separate, independently-published
[`ichor_runtime`](https://hex.pm/packages/ichor_runtime) package is.
`ichor` itself — the Aether front-end, every format importer,
`Grammar.Analysis`, the LR/GLR table builder, and both codegen backends
— never runs again once the file's been generated. A project that only
ever uses pregenerated parsers can reflect that directly in `mix.exs`:

```elixir
def deps do
  [
    {:ichor_runtime, "~> 0.1.0"},
    {:ichor, "~> 0.2.0", only: :dev, runtime: false}
  ]
end
```

`ichor` stops being something a `mix release` build ships at all — only
`ichor_runtime`, the small piece the generated code actually calls,
makes it into production. Regenerate by rerunning the same `mix
ichor.gen` command whenever `calculator.aether` changes; there's no
automatic staleness check between a checked-in generated file and its
source grammar, so it's worth wiring into a `mix.exs` alias of your own
(a `gen.grammar` alias calling `"ichor.gen ..."`, say) rather than typed
by hand each time.

`calculator.aether` doesn't have to be Aether source, either —
`mix ichor.gen` also accepts ABNF, BNF, ISO EBNF, and PEG grammars,
picking the style from the file's extension (`.abnf`, `.bnf`, `.ebnf`,
`.peg`) or an explicit `@style abnf` line in the source. This is meant
for reusing a grammar someone else already wrote in one of those
formats — an RFC's own ABNF, say — without hand-translating it to
Aether first; none of those formats have Aether's named captures or
`@skip` convenience, so the generated parser's `Ichor.Actions` module
only ever sees the default `Ichor.Node`/passthrough shape. See the
[cheatsheet](CHEATSHEET.md#compile-a-grammar-ahead-of-time-mix-ichorgen)
for the full extension table and `--root` flag.

If your grammar has a `@native(...)` rule or token whose own callback
needs something at *match* time — precedence-climbing expression parsing
(`Ichor.Toolkit.Pratt`, driving the Prolog `op/3` example in
[Examples](EXAMPLES.md)), generic term recursion
(`Ichor.Toolkit.TermWalk`), or a unification/backtracking engine
(`Ichor.Backtrack`) — those three are also part of `ichor_runtime`, not
`ichor`: they're genuinely standalone, useful to any engine built on top
of a generated parser, called on every match/evaluation rather than once
at codegen time.

## 9. Where to go from here

- [Examples](EXAMPLES.md) walks through several complete, working
  grammars covering different shapes of problem: a LISP dialect (special
  forms, macros), YAML (nested structure with zero custom actions), a
  query language, and more.
- [Cheatsheet](CHEATSHEET.md) is a quick reference once you know the
  shape of things and just need a reminder.
- The [Aether tutorial](aether/TUTORIAL.md) and
  [Aether reference](aether/AETHER.md) cover every Aether feature this
  tutorial only touched on: POSIX character classes, `@indent`/
  `@samecol` for layout-sensitive grammars, case-insensitivity, and more.
- [`ichor_runtime`'s own cheatsheet](https://hexdocs.pm/ichor_runtime/cheatsheet.html)
  covers `Ichor.Toolkit.Pratt`/`TermWalk`/`Ichor.Backtrack` in depth —
  worked examples for building an engine on top of a generated parser.
