defmodule Grammar.LRTable.Production do
  @moduledoc """
  One flat CFG production, `lhs -> rhs`, produced by `Grammar.LRTable.Desugar`
  from a grammar's PEG-shaped IR (`Seq`/`Choice`/`Star`/`Plus`/`Opt`/`Rep`
  each desugar to one or more of these; `Choice` in particular maps
  directly onto "more than one production for the same `lhs`" -- the
  natural CFG shape ordered PEG choice already resembles, minus the
  ordering).

  `captures` describes how to rebuild the exact same raw-capture shape
  `Ichor.Actions` expects (`{:token,...}`/`{:rule,...}`/`{:text,...}`) at
  reduce time, one entry per captured RHS position:

    - `{index, name, :token}` -- RHS position `index` is a bare (or
      explicitly named) reference to a *token*; becomes
      `{:token, terminal_name, text}` (or the token's own capture
      override, exactly like every other backend).
    - `{index, name, :rule}` -- same, but `index` names a *rule*; becomes
      `{:rule, nonterminal_name, child_captures}`.
    - `{index, name, :text}` -- `index` is a captured *composite*
      sub-expression (anything other than a direct bare `RuleRef` --
      `x:(a b)`, `x:"lit"`, `x:choice`, ...), desugared into its own
      helper nonterminal; becomes `{:text, span_text}`, the matched
      token text from that position's start to its end, exactly like
      `RuleCompiler.leaf/4`'s unconditional fallback for the same shape.
    - `{index, nil, :splice}` -- `index` is a helper nonterminal
      standing in for `Star`/`Plus`/`Rep`/`Opt` (or the left-recursive
      accumulator half of one) -- its own already-built captures map is
      merged key-by-key into this production's, list-accumulating
      exactly like `Ichor.Actions`' `merge_capture/3` does for a capture
      repeated inside an ordinary PEG `*`/`+`. This is what makes a
      repeated capture end up as a list in the *enclosing* rule's own
      capture map, rather than trapped one level down under a
      compiler-generated helper name nothing in `Ichor.Actions` knows
      about.

  An uncaptured RHS position (an anonymous auto-promoted literal token,
  the grammar's own spliced `@skip` token, or anything inside a
  `:text`-discarded span) has no entry in `captures` at all -- it
  contributes nothing to the built map, same as an anonymous token
  contributes no implicit self-capture on any other backend.
  """

  @type symbol :: {:terminal, atom()} | {:nonterminal, atom()}
  @type capture_kind :: :token | :rule | :text | :splice
  @type capture :: {non_neg_integer(), atom() | nil, capture_kind()}

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          lhs: atom(),
          rhs: [symbol()],
          captures: [capture()]
        }

  defstruct [:id, :lhs, rhs: [], captures: []]
end
