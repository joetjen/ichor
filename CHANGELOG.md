# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
