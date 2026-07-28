# Contributing to Ichor

Thanks for considering a contribution. This document covers what you need
to know before opening an issue or a pull request.

## Getting started

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
  backends (`Grammar.VM`, `Grammar.Native`).
- `lib/ichor/` — `Ichor.Actions` and the ABNF/BNF/EBNF/PEG format
  importers.
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
3. **Run the full verification pass before opening a PR:**

   ```sh
   mix format
   mix compile --warnings-as-errors --force
   mix test
   mix docs
   ```

4. **Match the existing documentation style.** Default to no comments;
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
