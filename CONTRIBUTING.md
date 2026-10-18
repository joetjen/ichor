# Contributing to Ichor

Thanks for considering a contribution. This document covers what you need
to know before opening an issue or a pull request.

## Getting started

`ichor` and [`ichor_runtime`](https://github.com/joetjen/ichor_runtime)
are two separate repositories, independently published and maintained
-- `ichor_runtime` is the small runtime support library a generated
parser actually calls at runtime (capture dispatch, error formatting,
the compiled Tokenizer/Parser combinators, the LR/GLR shift-reduce/GSS
runtime, plus the standalone `Ichor.Toolkit.Pratt`/`TermWalk`/
`Ichor.Backtrack`); this repository (`ichor`) depends on it via a
normal `~>` Hex version constraint, like any other dependency. If your
change touches something a *generated parser calls at match/evaluation
time*, you very likely want
[`ichor_runtime`'s own repo](https://github.com/joetjen/ichor_runtime)
and its own `CONTRIBUTING.md`, not this one.

```sh
git clone <this repository>
cd ichor
mix deps.get
mix test
```

That should complete with no failures on a clean checkout. If it
doesn't, please open an issue before doing anything else — that's a bug
in its own right.

## Project layout

- `lib/aether/` — the Aether lexer and parser (`.aether` source ->
  `Grammar.IR`).
- `lib/grammar/` — `Grammar.IR` itself, the analysis pass, and both
  backends (`Grammar.VM`, `Grammar.Native`), plus the LR/GLR table
  *builder* (`Grammar.LRTable.Builder`, `Automaton`/`Desugar`/`Sets`) —
  the dev-time-only half of LR/GLR support; the runtime half lives in
  `ichor_runtime`.
- `lib/ichor/` — the ABNF/BNF/EBNF/PEG format importers. `Ichor.Actions`
  itself, along with everything else a generated parser calls at
  runtime, lives in `ichor_runtime`'s own repo instead — see its README
  for the full list and the reasoning behind the split.
- `lib/mix/tasks/` — `mix ichor.tokens` and `mix ichor.gen`.
- `priv/grammar/` — the `.aether` sources the format importers compile
  from (read once, at compile time, via `use Ichor`).
- `test/` — one directory per worked-example grammar
  (`test/lisp/`, `test/yaml/`, ...), plus `test/support/` for shared
  test fixtures and Actions implementations.
- `guides/` — the documentation under `guides/`, published via ExDoc
  alongside the generated module docs.

## Making a change

1. **Tests first, or at least alongside.** A grammar-level change
   should come with a test exercising the actual input/output behavior,
   not just "does this parse." Several bugs found during this project's
   own development only showed up once a worked example was actually
   run end-to-end, not merely checked for successful parsing.
2. **Both backends, where it applies.** `Grammar.VM` and `Grammar.Native`
   are required to agree on every grammar's behavior. A change to
   shared semantics (an IR node's meaning, a compiler pass) needs
   verification against both, not just whichever one you happened to
   be testing against.
3. **Which repo does this belong in?** If you're adding something a
   *generated parser calls at match/evaluation time* (not just once at
   codegen time), it almost certainly belongs in `ichor_runtime`, not
   here — that was the exact gap `Ichor.Actions.evaluate_node/3` and
   `Ichor.Toolkit.Pratt`/`TermWalk`/`Ichor.Backtrack` were originally
   filed under before being moved (see CHANGELOG.md's `[Unreleased]`
   entry for the reasoning). If in doubt: does a project depending on
   `ichor_runtime` alone (with `ichor` `only: :dev, runtime: false`)
   still need it at runtime? If yes, it belongs in `ichor_runtime`,
   which means opening the PR against
   [that repo](https://github.com/joetjen/ichor_runtime) instead.
4. **Run `mix precommit` before opening a PR** (chains `format` ->
   `compile --warnings-as-errors` -> `credo --strict` -> `sobelow` ->
   `test` -> `dialyzer`):

   ```sh
   mix precommit
   ```

   Also run `mix docs` and skim the output for warnings — a broken
   moduledoc cross-reference or extras link won't fail the build but
   will show up there.

5. **Match the existing documentation style.** Default to no comments;
   when one is warranted, explain a non-obvious *why* (a hidden
   constraint, a subtle invariant, the specific bug class it prevents),
   not what the code already makes obvious by being well-named.
   Moduledocs should be self-contained — don't cite an external design
   document or a numbered "phase," since neither exists in this
   repository; document the library as it actually is.

## Adding a new grammar-format importer

If you're adding support for reading another external grammar notation
(along the lines of `Ichor.ABNF`/`Ichor.BNF`/`Ichor.EBNF.ISO`/
`Ichor.EBNF.W3C`/`Ichor.PEG`), the existing five are the template to
follow:

1. Write an `.aether` grammar describing the *target format's own
   syntax*, under `priv/grammar/`.
2. Write an `Ichor.Actions` implementation whose target category is
   `Grammar.IR` — turning a parsed rule of the external format into the
   equivalent `Grammar.IR` expression, the same way `Ichor.ABNF.Actions`
   or `Ichor.PEG.Actions` do.
3. Compile the pair via `use Ichor`, nested under `Ichor.*` (not a bare
   top-level module name), matching the existing five.
4. Verify the importer fails informatively (a normal `Ichor.Error`, not
   a crash) on syntax that isn't valid in your target format, not just
   that it succeeds on syntax that is.

## Reporting bugs

Please include: the grammar (or a minimal excerpt reproducing the
issue), the input, what you expected, and what actually happened
(including the full `Ichor.Error`, if one was raised). "Doesn't parse"
and "doesn't work" are much harder to act on than a specific
input/expected/actual triple.

## License

By contributing, you agree that your contributions will be licensed
under the project's [MIT license](LICENSE).
