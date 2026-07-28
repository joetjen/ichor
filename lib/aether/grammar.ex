defmodule Aether.Grammar do
  @moduledoc """
  The fully compiled output of `Aether.Parser`: grammar-wide settings plus
  every token and rule body, each already resolved to `Grammar.IR`.

  `tokens` holds every token -- user-declared, the five predefined ones
  (`DIGIT`/`ALPHA`/`ALNUM`/`SPACE`/`HEX`, overridden or defaulted), and
  anonymous ones auto-promoted from inline rule literals (a rule body
  writing a bare `"SELECT"` gets an anonymous token generated for it
  automatically, since only tokens participate in lexing) -- keyed by
  name. `rules` holds every rule body, already spliced with `@skip`/`~`.
  Downstream stages (the analysis pass, `Grammar.VM`, native codegen)
  consume this, not raw `.aether` text.

  `token_order` is the declaration order of every name in `tokens` --
  needed by the lexer's maximal-munch rule ("longest match wins, ties
  broken by declaration order"), which a plain map can't answer since
  Elixir maps don't preserve insertion order. Non-overridden predefined
  tokens are appended at the end, in their fixed table order, since they
  were never actually "declared" in the file.

  `anon_tokens` names every token auto-promoted from an inline rule
  literal rather than actually declared. `Grammar.VM`'s rule compiler
  consults this to skip *implicit* self-named captures for them -- a
  grammar author writing a bare `"("` clearly isn't asking to capture it
  under some compiler-generated name; if they wanted it captured, they'd
  give it a real name themselves.

  `rule_order` is the declaration order of every name in `rules` -- the
  same problem `token_order` solves for maximal munch, but for
  `Grammar.LRTable.Desugar`'s production numbering: a plain map can't
  answer "which rule was declared first," and `Grammar.GLR`'s
  declared-order tie-break among competing derivations needs that
  answer to be reliable across *every* rule in the grammar, not just
  among one rule's own alternatives (which a `Choice`'s own list order
  already preserves regardless of this field).

  `refiners` holds every `@keywords`/`@refine` reclassification rule,
  keyed by the base token it applies to -- `Grammar.Lexer` (the stage
  between the Tokenizer's raw output and the Parser) is what actually
  applies them, after every token's already been matched, before any
  rule runs.

  `engine` (default `:peg`) selects which parsing backend family a
  compiled grammar targets. `:peg` is every existing backend
  (`Grammar.VM`/`Grammar.Native`, plain recursive-descent PEG). `:lr`/
  `:glr` opt into `Grammar.LR`/`Grammar.GLR` instead -- genuinely
  different bottom-up shift-reduce engines, built for grammars that are
  left-recursive or outright ambiguous in ways plain PEG can't express.
  `Grammar.Analysis`'s left-recursion rewrite/rejection (a PEG-specific
  accommodation -- recursive descent can't handle left recursion at all)
  only runs when `engine == :peg`; `:lr`/`:glr` grammars keep left
  recursion exactly as written, since bottom-up parsing handles it
  natively. `Grammar.VM`/`Grammar.Native` refuse to run any grammar whose
  `engine != :peg`, since its left recursion was never rewritten and
  recursive descent over it would infinite-loop instead of failing
  cleanly.
  """

  @type refiner ::
          {:keywords, %{String.t() => atom()}}
          | {:custom, module :: module(), function :: atom(), possible_names :: [atom()]}

  @doc """
  Every name a `@keywords`/`@refine` rule can reclassify a token *to*
  (`KEYWORD_IF`, say) -- these never have their own `TOKEN := ...`
  definition, they only ever arise by renaming a match of their base
  token, so anything treating "is this name a token" as `Map.has_key?
  (grammar.tokens, name)` needs to union this set in too: both
  `Grammar.Analysis`'s dangling-reference check and each backend's
  `RuleCompiler` (token-ref vs. rule-ref is decided by this same
  membership test at compile time).
  """
  @spec refiner_target_names(%{atom() => refiner()}) :: MapSet.t(atom())
  def refiner_target_names(refiners) do
    Enum.reduce(refiners, MapSet.new(), fn
      {_base, {:keywords, table}}, acc -> MapSet.union(acc, MapSet.new(Map.values(table)))
      {_base, {:custom, _mod, _fun, possible}}, acc -> MapSet.union(acc, MapSet.new(possible))
    end)
  end

  @type engine :: :peg | :lr | :glr

  @type t :: %__MODULE__{
          name: String.t(),
          root: atom(),
          skip: atom() | nil,
          case_insensitive: boolean(),
          engine: engine(),
          tokens: %{atom() => Grammar.IR.expr()},
          token_order: [atom()],
          anon_tokens: MapSet.t(atom()),
          rules: %{atom() => Grammar.IR.expr()},
          rule_order: [atom()],
          refiners: %{atom() => refiner()},
          source: String.t() | nil,
          file: String.t() | nil
        }

  defstruct [
    :name,
    :root,
    skip: nil,
    case_insensitive: false,
    engine: :peg,
    tokens: %{},
    token_order: [],
    anon_tokens: MapSet.new(),
    rules: %{},
    rule_order: [],
    refiners: %{},
    source: nil,
    file: nil
  ]
end
