# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Breaking:** bumped `ichor_runtime` to `~> 0.2` (from `~> 0.1.0`), whose
  0.2.0 changed raw capture data (`Ichor.Capture.node_t/0`'s `:rule`
  variant, and therefore every `parse/1`-style bare-recognizer function
  `use Ichor`/`Grammar.Native`/`Grammar.Native.LR`/`Grammar.Native.GLR`/
  `Grammar.LR`/`Grammar.GLR`/`Grammar.VM` generate or expose) from a
  plain `%{name => value}` map to an ordered `[{name, value}]` list
  (`Ichor.Capture.raw_captures/0`), fixing sibling-capture evaluation
  order depending on a plain map's own (cross-OTP-version-unstable)
  iteration order instead of true first-occurrence source order. Ported
  the same fix to `Grammar.VM.TokenInterpreter` (this project's own
  reference/interpreted PEG path, which ichor_runtime doesn't own) for
  parity with the native backend, and updated `Grammar.Native.RuleCompiler`'s
  generated code and `Ichor.GrammarImport`'s hand-written capture
  pattern-matches to the new list shape. Any hand-written
  `Ichor.Actions` module that pattern-matches or constructs
  `raw_captures`/`node_t()` values directly (e.g. for macro-expansion
  via `Ichor.Actions.evaluate_node/3`) needs the same `%{name: value}`
  -> `[{name, value}]`/`[name: value]` update -- the already-*evaluated*
  `Ichor.Actions.captures/0` map handed to `handle_rule/3` callbacks is
  unchanged.

## [0.2.1] - 2026-07-29

### Changed

- **Documentation reframed around three ways to run a grammar**, with
  `mix ichor.gen` established as the recommended default for anything
  shipping to production: README gained a "Three ways to run a grammar"
  section (`mix ichor.gen` / `use Ichor` / the raw `Aether.Parser` +
  `Grammar.Analysis` + `Grammar.VM` pipeline) spelling out the concrete
  reason for that recommendation -- `use Ichor` needs the real `Ichor`
  module present at compile time in whatever environment you compile
  in, so `ichor` can't be `only: :dev, runtime: false` in any app that
  still has one, including a `mix release` build (which normally
  compiles under `MIX_ENV=prod`); `mix ichor.gen` output has no macro
  dependency on `ichor` at all, so it's the only path that actually
  allows the dev-only split `ichor_runtime` exists to enable. The
  tutorial gained a new §8, "Loading a grammar at runtime", with a
  worked plugin-loader example for the third path (previously only
  mentioned in passing, never actually demonstrated); the cheatsheet
  gained a "Which one do I want?" comparison table and was reordered to
  match; the `Ichor`/`Mix.Tasks.Ichor.Gen`/`Grammar.VM` moduledocs now
  name and cross-reference all three paths for readers landing there
  directly via ExDoc/hex search.

### Fixed

- Three pre-existing broken anchor links across the guides (`guides/
  TUTORIAL.md`, `guides/CHEATSHEET.md`, `guides/aether/TUTORIAL.md`,
  `guides/EXAMPLES.md`) -- ExDoc's markdown renderer turns a period
  inside a backtick-quoted heading (`` `mix ichor.gen` ``,
  `` `Ichor.Actions` ``) into an extra hyphen when generating the
  heading's own anchor id (`mix-ichor-gen`, `ichor-actions`), not just
  stripping it, which none of the existing cross-reference links
  accounted for. ExDoc doesn't validate these at build time, so they'd
  been silently dead since introduced.

## [0.2.0] - 2026-07-29

### Added

- **`mix ichor.gen`**: runs the parse/analyze/native-codegen pipeline
  ahead of time and writes the result to a plain `.ex` file, instead of
  `use Ichor` re-running it inside a macro expansion on every compile.
  Every generated helper function is emitted as `def` rather than
  `defp` (macro-originated code is exempt from Elixir's unused-function
  check; written out as ordinary source, it isn't). `Ichor.generate/3`
  is the new public entry point both `__using__/1` and the task share.
- **`Ichor.GrammarImport`**: turns an ABNF/BNF/ISO-EBNF/PEG ruleset (as
  `Ichor.ABNF`/`Ichor.BNF`/`Ichor.EBNF.ISO`/`Ichor.PEG` produce them --
  not a runnable `Aether.Grammar` on their own) into one that is: picks
  a root (the source's own first-declared rule, overridable), always
  `@noskip`, auto-promotes bare literals/char-classes into synthetic
  tokens, and -- for ABNF specifically -- fills in whichever of RFC
  5234 Appendix B's "core rules" (`ALPHA`, `DIGIT`, `CRLF`, ...) the
  source references but never defines, restricted to their transitive
  closure so unreferenced, overlapping core rules (`CHAR`/`OCTET`
  overlapping `DIGIT`, e.g.) can't win a maximal-munch tie against a
  token a rule actually meant. `mix ichor.gen` now accepts any of these
  formats directly (`.abnf`/`.bnf`/`.ebnf`/`.peg`, auto-detected from
  the file extension, or forced with an `@style` pragma line), with a
  new `--root NAME` flag for the non-Aether entry-rule override.
- **[`ichor_runtime`](https://github.com/joetjen/ichor_runtime)**: split
  out of `ichor` proper -- the ~24 modules a generated parser (from
  `mix ichor.gen` or `use Ichor`) actually calls at runtime
  (`Ichor.Actions`, `Ichor.Error`, the compiled Tokenizer/Parser
  combinators, the LR/GLR shift-reduce/GSS runtime, and standalone
  `Ichor.Toolkit.Pratt`/`TermWalk`/`Ichor.Backtrack`), with everything
  dev-time-only (the Aether front-end, format importers,
  `Grammar.Analysis`, the LR/GLR table builder, both codegen backends)
  staying in `ichor`. `Grammar.LRTable` was split in the process: the
  struct plus `current_terminal/3`/`unexpected_error/2` (genuinely
  called at match time) moved to `ichor_runtime`; table construction
  (`build/1`/`conflicts/1`, which need `Automaton`/`Desugar`/`Sets`)
  stays in `ichor` as the new `Grammar.LRTable.Builder`. Independently
  published ([`ichor_runtime` 0.1.0](https://hex.pm/packages/ichor_runtime))
  and maintained -- its own repository, its own release cadence -- not
  a subdirectory of this one; `ichor` depends on it via a normal `~>
  0.1.0` Hex version constraint (its own interpreted backends need it
  too).

### Fixed

- `evaluate_node/3` moved from the top-level `Ichor` module to
  `Ichor.Actions.evaluate_node/3` -- found while migrating a real
  downstream consumer (`dextrin`) to the `ichor`/`ichor_runtime` split:
  it's a genuine runtime entry point (any grammar with macro-like
  features needs it to evaluate its own expansion, not just LISP's
  worked example), not a compile-time-only concern like `generate/3`/
  `__using__/1`, which are the only two things that actually belong in
  the dev-only `ichor` package. Left in `Ichor` proper, it would have
  been unavailable at runtime to anything depending on `ichor_runtime`
  alone, exactly as the split intends.
- `Ichor.Toolkit.Pratt`, `Ichor.Toolkit.TermWalk`, and `Ichor.Backtrack`
  (+ `.Bindings`/`.Term`/`.Tree`) moved from `ichor` to `ichor_runtime` --
  the same class of gap as `evaluate_node/3` above, found migrating
  another real downstream consumer (Aletheia): a `@native(...)` rule's
  own callback module (Prolog-style operator-precedence parsing, the
  worked example this whole feature is motivated by -- see
  `test/prolog/`) calls `Ichor.Toolkit.Pratt.parse/4` on every single
  parse, not just once at grammar-generation time, and a consuming
  engine built on `Ichor.Backtrack` calls into `Bindings`/`Tree` on every
  resolution step. None of the three have any dev-only dependency of
  their own (`Pratt` operates on a plain map, `Backtrack` is
  self-contained, `TermWalk` only needs `Backtrack.Term`), so keeping
  them in the dev-only package was an oversight in the original split,
  not a deliberate exclusion. `Ichor.Toolkit.TypeScheme` (which stays in
  `ichor` -- it's a compile-time type-checking concern) depends on both
  `Bindings` and `TermWalk`; unaffected by the move since `ichor` already
  depends on `ichor_runtime`.

## [0.1.1] - 2026-07-28

### Added

- `@native(...)`/`@hint(...)` at **rule position** (`Grammar.IR.Custom`):
  an escape hatch for grammar rules plain PEG can't express — most
  notably a runtime-mutable operator-precedence table (Prolog's `op/3`,
  Haskell fixity declarations, Coq/Agda/Lean mixfix notation),
  dispatching to an author-supplied `c:Ichor.CustomRule.match/4`-shaped
  callback with access to the token stream, the current position, the
  grammar's own `context` (read-only, threaded via `run_sequence/4`
  across top-level forms), and `rule_matchers` restricted to the node's
  own declared dependencies.
- `@native(...)`/`@hint(...)` at **token position**
  (`Grammar.IR.CustomLexeme`/`Ichor.CustomLexeme`): the analogous escape
  hatch for lexing that fixed maximal-munch tokenization can't express —
  heredocs (the terminator is read off the source itself), string
  interpolation (a token needing to recurse into a rule mid-scan), and
  in principle TeX-style `\catcode` mutation. Includes a new "re-lex and
  match rule R starting at a given character position" primitive
  (`rule_matchers.name.(input, char_pos)`), supported by both backends.
- **`@engine peg | lr | glr`** pragma (default `peg`, fully backward
  compatible): selects the parsing algorithm for `@root`, independent of
  execution strategy (interpreted vs. compiled):
  - **`Grammar.LR`** (and `Grammar.Native.LR` for compiled codegen): a
    from-scratch SLR(1) table (`Grammar.LRTable`) plus a deterministic
    shift-reduce engine, for grammars an author has already verified are
    conflict-free — zero GSS/backtracking bookkeeping, and (compiled)
    fully inlined into one Elixir function per automaton state.
  - **`Grammar.GLR`** (and `Grammar.Native.GLR`): genuine Tomita-style
    GLR over the same SLR(1) table, forking at every real conflict via a
    graph-structured stack (`Grammar.GLR.GSS`) that shares/merges
    history instead of naively duplicating parallel stacks, resolving
    multiple valid derivations via a declared-order tie-break
    (`Grammar.LRTable.Automaton`'s own canonical "shift before reduce,
    reduces by production id" conflict-cell ordering) — this is what
    lets it parse inputs plain PEG's greedy, non-backtracking commit can
    never recover from, and pick a deterministic winner for genuine
    CFG-level ambiguity a PEG grammar could never even express.
  - `Grammar.Analysis` skips its PEG-specific left-recursion rewrite for
    non-`peg` grammars (left recursion is what bottom-up shift-reduce
    parsing wants, not a hazard); both backends guard against running a
    mismatched-`@engine` grammar through the wrong entry point.
- **`@keywords` / `@refine`**: token-stream reclassification after
  tokenization, before parsing (`Grammar.Lexer.reclassify/2`) —
  `@keywords WORD { "if" -> KEYWORD_IF, ... }` is table-lookup sugar for
  the general case, `@refine(Module, :function)` dispatches to an
  author-supplied callback with the already-reclassified stream so far
  (enabling lookbehind-dependent reclassification, e.g. JavaScript's
  regex-literal-vs-division-operator ambiguity).
- **`Ichor.Backtrack`**: a generic lazy-search-plus-unification
  substrate for logic-language evaluation models (SLD-resolution and
  friends) — `Ichor.Backtrack.Tree` (`unit`/`fail`/`disjunction`/
  `conjunction`/`once`, pulled lazily via `next/1`, depth-first/
  left-to-right like Prolog's own clause-order backtracking),
  `Ichor.Backtrack.Bindings` (a substitution: `bind`/`resolve`/`unify`/
  `unify_occurs_check`, over any `Ichor.Backtrack.Term` implementation
  an author supplies for their own term representation).
- **`Ichor.Toolkit`**, small IR-agnostic building blocks extracted from
  patterns Ichor's own compiler internals had already independently
  hand-rolled more than once — useful to a grammar author's own
  downstream semantic analysis/type inference/codegen, never run by
  Ichor itself:
  - `Fixpoint`/`Graph` — "iterate a step function to convergence," and
    reachability/cycle detection over an arbitrary graph.
  - `Scope` — a generic nested lexical scope/symbol table.
  - `TypeScheme` — Hindley-Milner-style let-polymorphism
    (`generalize`/`instantiate`/`resolve_deep`) built on
    `Ichor.Backtrack.Bindings.unify_occurs_check/4`.
  - `Codegen` — small `quote`/`unquote` mechanics (`fresh`/`vars`/
    `indexed_vars`/`capture`/`clause`) for authors hand-writing their
    own Elixir-codegen backend.
  - `Result` — `reduce_ok`/`map_ok`, an `Enum.reduce`-with-early-exit-
    on-failure pair for the "walk a collection, thread an accumulator
    through a fallible step" idiom.
  - `Pratt` — precedence-climbing (Pratt) expression parsing over a
    runtime-mutable operator table (prefix/infix/postfix, including the
    genuinely ambiguous case of an operator registered as both infix and
    postfix at once).
  - `Layout` — the Python/Haskell/F#-style off-side-rule (`INDENT`/
    `DEDENT` token synthesis) algorithm, an alternative strategy to
    Aether's own `@indent`/`@samecol`.
  - `TermWalk` — generic `fold`/`rewrite` recursion over any
    `Ichor.Backtrack.Term` implementation.
- Native GLR/LR codegen (`Grammar.Native.LR`/`Grammar.Native.GLR`): the
  SLR(1) table is built once, at Elixir-compile-time, instead of on
  every call; `Grammar.Native.LR` fully inlines shift/reduce dispatch
  into one Elixir function per automaton state (a genuine Bison-style
  compiled parser), `Grammar.Native.GLR` compiles the action/goto lookup
  tables while sharing one runtime GSS engine (`Grammar.GLR.Runtime`)
  with the interpreted backend.
- Five more worked-example grammars, chosen specifically to close gaps
  where a feature had only ever been exercised by a synthetic/textbook
  fixture, never anything relating to a real programming language, file
  format, or protocol:
  - **Prolog** (`test/prolog/`) — real clause/rule/directive syntax
    (facts, rules with conjunction, `:- op(Prec, Type, Name).`
    directives genuinely mutating the operator table mid-file via
    `Ichor.Toolkit.Pratt` + `run_sequence/4`'s context threading),
    closing the loop with `Ichor.Backtrack`: a parsed fact unifies
    directly against a hand-built query term through the same substrate.
  - **The classic dangling-else ambiguity** (`test/dangling_else/`) —
    real, present in C/Java/JavaScript/PHP, resolved correctly (else
    binds to the nearest `if`) with no special-casing needed.
  - **CommonMark thematic breaks** (`---` -> `<hr>`, added to the
    existing Markdown grammar) — the first real use of `&expr`
    (`Grammar.IR.AndPred`) anywhere in the test suite.
  - **A classic-BNF LISP fixture** (`test/lisp/lisp.bnf`) —
    `Ichor.BNF`'s first real-world-named fixture.
  - **A W3C-EBNF XML subset** (`test/xml/`) — `Ichor.EBNF.W3C`'s first
    real-world-named fixture, keeping the real XML 1.0 spec's own
    production names.

### Changed

- Split `Aether.Parser` into `Aether.Reader` (pure-syntax parsing of
  `.aether` source into a concrete syntax tree, no desugaring) and
  `Aether.Eval` (that CST into `Grammar.IR`/`Aether.Grammar`, owning
  predefined-token override/use tracking, case-insensitivity resolution,
  character-class/regex desugaring, inline-literal promotion, and
  `@skip` splicing). Mirrors the Reader/Eval split generated grammar code
  already has (`parse/1` vs. `run/1,2`) and the ABNF/BNF/EBNF/PEG
  importers already inherit from it. `Aether.Parser.parse/2` remains the
  combined entry point; observable behavior is unchanged.
- Split the tokenizer/lexer/parser pipeline into four explicit stages,
  shared identically by both backends: `Grammar.Source` (UTF-8
  validation), `Grammar.VM.Tokenizer`/`Grammar.Native.Runtime.Tokenizer`
  (renamed from `Lexer`/`Grammar.Native.Runtime` — maximal-munch
  char-level matching), `Grammar.Lexer` (new — `@keywords`/`@refine`
  reclassification, shared by both backends since it's pure
  post-tokenization data processing), and the existing token-level
  Parser stage (`Grammar.Native.Runtime.Parser`, split out of
  `Grammar.Native.Runtime`).
- `Aether.Grammar` gained `rule_order` (mirroring the existing
  `token_order`) and an `engine` field (`:peg` by default).
- Renamed `LICENSE.txt` to `LICENSE`.

## [0.1.0] - 2026-07-26

### Added

- **Aether**, Ichor's own grammar language: `ALL_CAPS` tokens matched by
  maximal munch, `snake-case`/`kebab-case` rules matched by ordered PEG
  choice, string/character-class/regex-literal primitives, quantifiers
  (`*`/`+`/`?`/`{n,m}`), lookahead predicates (`&`/`!`), named captures,
  automatic `@skip` whitespace-splicing (with `@noskip` and `~` to opt
  out), `@case_insensitive`, POSIX bracket classes, and `@indent`/
  `@samecol` for layout-sensitive grammars.
- `Grammar.IR`, the normalized AST every front-end compiles to and every
  backend consumes.
- `Grammar.Analysis`: reference checks, a direct-left-recursion rewrite,
  an empty-repetition hazard check, and a duplicate-alternative lint.
- `Grammar.VM`, an interpreted bytecode backend (LPeg-style compiled
  Lexer + Parser).
- `Grammar.Native`, a compile-time codegen backend (`use Ichor`),
  generating direct Elixir function calls instead of bytecode.
- `Ichor.Actions`, the behaviour connecting a parsed grammar to real
  evaluation, transpilation, or execution: `handle_rule/3`,
  `handle_token/3`, optional `finalize/1`, and a default fallback for
  anything a grammar's own Actions module doesn't implement.
- Format importers reading ABNF (RFC 5234 + RFC 7405), classical BNF
  (ALGOL 60 Report convention), ISO/IEC 14977 EBNF, W3C-style EBNF (the
  notation the XML 1.0 spec's own section 6 uses), and PEG (Ford's
  paper / pest / PEG.js convention) — each producing the same
  `Grammar.IR`-based ruleset shape every other front-end produces.
- `mix ichor.tokens`, listing every token a grammar declares in
  maximal-munch tie-break order.
- Nine worked-example grammars exercising the library end to end:
  a calculator, a LISP dialect, YAML, LogQL, SQL, HTTP, regex, Forth,
  and a Markdown-to-HTML transpiler.
- Cross-format validation: six of those worked examples (calculator,
  LISP, LogQL, SQL, HTTP, regex) independently re-expressed in ABNF,
  ISO EBNF, and PEG, verified to produce equivalent tokens and
  identical accept/reject behavior to their native Aether counterparts.
