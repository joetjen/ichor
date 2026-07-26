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

## 8. Where to go from here

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
