# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
