# IchorRuntime

The small runtime support library [Ichor](https://hex.pm/packages/ichor)-generated
parsers call into. Every parser `mix ichor.gen` writes to disk, and every
module `use Ichor, grammar: ..., actions: ...` splices code into, resolves
a handful of module names at runtime -- `Ichor.Actions`, `Ichor.Error`,
`Grammar.Native.Runtime.Parser`/`Tokenizer`, `Grammar.VM.Token`, and (for
`@engine lr`/`glr` grammars) the LR/GLR shift-reduce and GSS runtime. This
package is exactly that set, and nothing else.

Ichor itself -- the Aether grammar language, its ABNF/BNF/EBNF/PEG
importers, `Grammar.Analysis`, the LR/GLR table builder, and both codegen
backends -- never runs after a grammar's been compiled. Splitting it out
this way means a project that only ever runs `mix ichor.gen` ahead of
time can depend on `ichor_runtime` as an ordinary dependency, and on
`ichor` itself as `only: :dev, runtime: false` -- the bulk of the
library (grammar parsing, analysis, and codegen) never ships to
production.

```elixir
def deps do
  [
    {:ichor_runtime, path: "packages/ichor_runtime"},
    {:ichor, only: :dev, runtime: false}
  ]
end
```

A project that instead loads/compiles grammars at runtime (via
`Grammar.VM`, `Grammar.LR`, or `Grammar.GLR`, rather than pregenerated
code) still needs the full `ichor` package as a normal dependency --
`ichor_runtime` is a piece Ichor's own interpreted backends depend on
too, not a replacement for it.

See the main [Ichor README](../../README.md) for the full picture.
