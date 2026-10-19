# Lossless mode

Status: **agreed** by Jan on 2026-10-19, with all three recommendations
below taken.

Asked for by Dextrin (`dextrin/design/comment-retention.md`, phase C of
`dextrin/design/implementation-plan.md`): `Dextrin.Document` needs a
tree of a DXN file that keeps every byte, so that an edited document
renders back with its comments and layout intact. Nothing in that need
is DXN-specific. This document designs it for any Ichor grammar.

## What is asked

1. A parser generated from a `.aether` keeps what `@skip` discards --
   comments, whitespace -- as tokens with source positions.
2. It produces a **full-fidelity tree** for any grammar, from the same
   `.aether`: no second grammar, in Elixir or in Praxis, to keep in step.
3. **The ordinary parser stays as it is.** Its speed, its result and the
   code generated for it do not change. Only a caller who asks for the
   lossless parser gets it.
4. Separately, and smaller: `Ichor.Error` gains an optional `data`
   field, so an action can fail with its own error inside an
   `Ichor.Error` instead of beside it. That lets Dextrin drop its one
   dialyzer ignore.

## What the parsers do today

Read before designing, since the shape follows from it:

- **The token stream already holds everything.** The tokenizer emits
  every token, skip tokens included, with line and column. Nothing is
  dropped in the lexer. `@skip` works later: `Aether.Eval` splices a
  `SKIP*` in front of every element of a rule's sequence but the first,
  and leaves the skip token out of the captures
  (`implicit_capture_exclusions/1`). `Grammar.Source.trimmed/2` takes
  the skip tokens off both ends of the stream before the root is
  matched.
- **Captures cannot be turned into a tree after the fact.** They are
  keyed by name, and a name captured twice is merged into one slot
  (`merge_capture/3`). So the order of differently named captures is
  lost, and so is everything uncaptured: literals, anonymous tokens and
  trivia. A lossless tree has to be recorded while matching. It cannot
  be rebuilt from the result.
- **Every engine knows each rule's token range at the moment it
  finishes.** For the PEG VM and the native PEG parser, that is the stream
  position on entering a rule and on returning from it. For LR and GLR,
  it is the `pos`/`new_pos` that every stack entry already carries.
  Recording, per successful rule, `{rule, from, to, children}` is all
  that is needed. Backtracking already discards a failed alternative's
  frame, and the record would live in that same frame, so a failed
  alternative leaves no trace.

## The design

### Two passes, one of them cheap

The lossless parser is the ordinary parser with one addition: every
successful rule invocation is recorded as `{rule, from, to, children}`,
in source order, in the frame that already holds its captures. After
the match, one linear pass **weaves** the token stream into that rule
tree: each token becomes a leaf of the deepest rule whose range
contains it.

The ordinary captures are still built in the same pass. So the lossless
parser returns the ordinary result *and* the tree. A caller gets the
value through the same actions the fast parser runs, rather than a
second projection to keep in step. That answers the strongest
objection in Dextrin's own open questions, "the maintenance tax", for
the read side.

### The tree

Two structs, in `ichor_runtime`, because generated parsers need them at
run time:

```elixir
%Ichor.Syntax.Node{
  rule: atom(),                     # the grammar rule that matched
  children: [Node.t() | Token.t()], # in source order
  offset: non_neg_integer(),        # byte offset of the first byte
  size: non_neg_integer(),          # bytes covered
  line: pos_integer(),              # where it starts
  column: pos_integer()
}

%Ichor.Syntax.Token{
  name: atom(),                     # token name; ANON_n for a literal
  text: String.t(),
  trivia: boolean(),                # it is the grammar's @skip token
  offset: non_neg_integer(),
  line: pos_integer(),
  column: pos_integer()
}
```

`Ichor.Syntax` itself holds the functions over the tree:

- `text/1`: the bytes a node or token covers.
- `tokens/1`: its tokens, in order.

Byte offsets are what make Dextrin's render rule cheap: an untouched
node emits `binary_part(source, offset, size)`. The tokenizer does not
track offsets today, and adding that would cost the fast path. So the
weave computes them, summing `byte_size(text)` as it walks the stream
once.

**Invariants**, each one tested, by property where the input space
calls for it:

1. **Lossless.** `Ichor.Syntax.text(root) == input`, byte for byte, for
   every input the ordinary parser accepts.
2. **Ordered.** The leaves, read left to right, are the token stream.
3. **Trivia sits between, never at an edge.** No node other than the
   root begins or ends with a trivia token. A trivia token belongs to
   the deepest node that has something significant on *both* sides of
   it. The input's leading and trailing trivia belong to the root.
4. **Same decision as the fast parser.** The lossless parser accepts
   exactly what the ordinary one accepts, fails with the same error
   word for word, and returns the same value.

Invariant 3 is not how the match happens to fall. `a b?` consumes the
trivia before a `b` that turns out to be absent, so that trivia lies
inside `a b?`'s range. The weave hoists it out. Without that, where
trivia lands would depend on how the grammar is written rather than on
the text. Dextrin's above/between/trailing ownership is then decided
over a node's siblings, with each trivia token's line in hand. Ichor
does not decide ownership: that is a policy of the consumer, and a
different format would want a different one.

**Which rules become nodes.** Every grammar rule that matched becomes a
node, including the ones the ordinary tree passes through because they
captured one thing. The ordinary tree's shortcuts are a convenience for
actions. In a tree meant for editing they would hide structure.
Rules the grammar's author never wrote do not appear: the helpers that
LR desugaring introduces for `*`, `+` and `?` are spliced into their
parent. A rule that matched nothing is an empty node at the position
where it matched.

**No capture labels, for now.** A child does not say which `name:`
captured it. Dextrin finds an entry's key and value by rule name, and a
`label` field can be added later without breaking anything.

### Engines and backends

All three engines, on both backends. "Any grammar" means a grammar
moving from `@engine peg` to `lr` keeps its lossless tree.

| | PEG | LR | GLR |
|---|---|---|---|
| Interpreted (`ichor`) | `Grammar.VM`: the frame gains `nodes` | `Grammar.LR`: a reduction builds the node from its stack entries | `Grammar.GLR`: the same, on the path the run already keeps |
| Native (generated) | a second set of rule functions | the shared LR runtime in `ichor_runtime` | the shared GLR runtime |

GLR breaks a surviving ambiguity by a recorded choice. The lossless run
makes the same choice, so invariant 4 holds there too.

### Opt-in, at generation

```elixir
use Ichor, grammar: "dxn.aether", actions: Dextrin.Actions, lossless: true
```

```sh
mix ichor.gen dxn.aether --lossless
```

With the option, the generated module gains `parse_lossless/1` and
`run_lossless/1,2`. The latter returns `{:ok, value, %Ichor.Syntax.Node{}}`.
Without it, the generated code is **unchanged**, which is checked by
comparing generated source before and after on the test grammars. The
interpreted backends get `Grammar.VM.parse_lossless/3`,
`Grammar.LR.parse_lossless/3` and `Grammar.GLR.parse_lossless/3`.

**Why opt-in.** For the native PEG backend, recording the rule tree
changes what every rule function threads through. Doing that behind a
run-time flag would put a check in the fast path of every parser. A
second set of functions keeps the fast path untouched, at the cost of
roughly doubling the generated parser. Only a grammar that asks for it
should pay that.

### `Ichor.Error.data`

```elixir
%Ichor.Error{..., data: term()}   # nil unless something put it there
```

`data` is for whatever a stage wants to hand through with its error.
Mostly that is an action failing with its own domain error, which the
caller unwraps. `format/1` ignores it.

The rebuild in `Grammar.Source.shown/2` lists every field by name, and
so does its Praxis port, `ichor.runtime.grammar.source/shown`. That
rebuild must carry `data`, or an LR error placed against its input loses
it silently. There is a test for that.

## Releases

Ichor's own order: runtime first, because the generator depends on it.

1. **`ichor_runtime` 0.4.0**: `Ichor.Syntax` and its structs, the weave,
   lossless support in the shared LR and GLR runtimes, and
   `Ichor.Error.data`. Dextrin can take the `data` field from this
   release alone.
2. **`ichor` 0.5.0**: `lossless: true` / `--lossless`, the interpreted
   backends' `parse_lossless/3`, `"~> 0.4"` on `ichor_runtime`, and a
   guide section.

Then the Praxis ports (`libs_prx/ichor_runtime`, `libs_prx/ichor`,
`ichor_prx`'s generator), in Praxis's names: records in
`ichor.runtime.syntax`, `gen --lossless`. They stay one step ahead of
the Elixir release and unreleased, under the porting rule.

Then `ichor_conformance` gains a `lossless` operation: the tree, as
typed data, compared across all four implementations, plus invariant 1
on every existing `parse` case. That is how "no second grammar to keep
in step" is checked, rather than hoped for.

## Not in this

- **Incremental reparsing** (rowan's green/red split, reusing untouched
  subtrees). Dextrin re-parses whole documents, and they are small.
- **Editing the tree.** Insert, delete and replace are Dextrin's API
  over its own format. Ichor supplies the tree and its invariants.
- **Splitting a trivia token.** DXN's `TRIVIA := (SPACE | COMMENT)*` is
  one token, so a run of comments and blank lines arrives as one leaf.
  Dextrin can split it, re-tokenizing just that text, or it can change
  `@skip` to a token that matches one space-run or one comment, and let
  `SKIP*` repeat it. Ichor keeps tokens as the grammar defines them.

## Decided

Jan agreed all three on 2026-10-19:

1. **Opt-in at generation**, not always generated: a second set of rule
   functions roughly doubles a generated parser, and only a grammar that
   asks should pay for it.
2. **`run_lossless` returns the value too**: the captures are built in
   the same pass anyway, and it gives Dextrin `decode/1`'s exact value.
3. **Trivia is hoisted** (invariant 3): leaving it where the match put it
   would make two equivalent ways of writing a rule give different trees.
