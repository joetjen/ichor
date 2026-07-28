defmodule Grammar.IR do
  @moduledoc """
  The normalized grammar AST every Ichor front-end (Aether, ABNF, BNF,
  EBNF, PEG) compiles down to, and that every later stage -- the analysis
  pass, `Grammar.VM`, native codegen -- consumes instead of talking to any
  particular front-end's own syntax.

  Each of the fourteen node types below is its own struct, so later stages
  can dispatch on node shape with ordinary pattern matching:

      def compile(%Grammar.IR.Seq{exprs: exprs}), do: ...
      def compile(%Grammar.IR.Choice{exprs: exprs}), do: ...

  Every node also carries `meta: %Grammar.IR.Meta{}` -- source-location
  info that lets an error always point back to the original grammar file,
  never just the IR.

  This module's functions are thin constructors: they exist so callers
  don't have to spell out `%Grammar.IR.Seq{exprs: ..., meta: ...}` by hand
  everywhere, and to have one place documenting each node's shape via a
  doctest.
  """

  alias Grammar.IR.{
    AndPred,
    Any,
    Capture,
    CharClass,
    Choice,
    Custom,
    CustomLexeme,
    Indent,
    Literal,
    NotPred,
    Opt,
    Plus,
    Rep,
    RuleRef,
    Seq,
    Star
  }

  @type expr ::
          Seq.t()
          | Choice.t()
          | Star.t()
          | Plus.t()
          | Opt.t()
          | Rep.t()
          | AndPred.t()
          | NotPred.t()
          | Literal.t()
          | CharClass.t()
          | Any.t()
          | RuleRef.t()
          | Indent.t()
          | Capture.t()
          | Custom.t()
          | CustomLexeme.t()

  @doc """
  Ordered sequence of sub-expressions.

      iex> Grammar.IR.seq([Grammar.IR.literal("a"), Grammar.IR.literal("b")])
      %Grammar.IR.Seq{
        exprs: [%Grammar.IR.Literal{value: "a"}, %Grammar.IR.Literal{value: "b"}],
        meta: %Grammar.IR.Meta{}
      }

  """
  @spec seq([expr()], Grammar.IR.Meta.t()) :: Seq.t()
  def seq(exprs, meta \\ %Grammar.IR.Meta{}), do: %Seq{exprs: exprs, meta: meta}

  @doc """
  Ordered PEG choice -- first match wins, always.

      iex> Grammar.IR.choice([Grammar.IR.literal("+"), Grammar.IR.literal("-")])
      %Grammar.IR.Choice{
        exprs: [%Grammar.IR.Literal{value: "+"}, %Grammar.IR.Literal{value: "-"}],
        meta: %Grammar.IR.Meta{}
      }

  """
  @spec choice([expr()], Grammar.IR.Meta.t()) :: Choice.t()
  def choice(exprs, meta \\ %Grammar.IR.Meta{}), do: %Choice{exprs: exprs, meta: meta}

  @doc """
  Zero or more.

      iex> Grammar.IR.star(Grammar.IR.rule_ref(:digit))
      %Grammar.IR.Star{expr: %Grammar.IR.RuleRef{name: :digit}, meta: %Grammar.IR.Meta{}}

  """
  @spec star(expr(), Grammar.IR.Meta.t()) :: Star.t()
  def star(expr, meta \\ %Grammar.IR.Meta{}), do: %Star{expr: expr, meta: meta}

  @doc """
  One or more.

      iex> Grammar.IR.plus(Grammar.IR.rule_ref(:digit))
      %Grammar.IR.Plus{expr: %Grammar.IR.RuleRef{name: :digit}, meta: %Grammar.IR.Meta{}}

  """
  @spec plus(expr(), Grammar.IR.Meta.t()) :: Plus.t()
  def plus(expr, meta \\ %Grammar.IR.Meta{}), do: %Plus{expr: expr, meta: meta}

  @doc """
  Zero or one.

      iex> Grammar.IR.opt(Grammar.IR.rule_ref(:sign))
      %Grammar.IR.Opt{expr: %Grammar.IR.RuleRef{name: :sign}, meta: %Grammar.IR.Meta{}}

  """
  @spec opt(expr(), Grammar.IR.Meta.t()) :: Opt.t()
  def opt(expr, meta \\ %Grammar.IR.Meta{}), do: %Opt{expr: expr, meta: meta}

  @doc """
  Bounded repetition `{n,m}`. `max: :infinity` expresses the open-ended
  `{n,}` form; `min == max` expresses the exact `{n}` form.

      iex> Grammar.IR.rep(Grammar.IR.rule_ref(:digit), 1, 3)
      %Grammar.IR.Rep{expr: %Grammar.IR.RuleRef{name: :digit}, min: 1, max: 3, meta: %Grammar.IR.Meta{}}

  """
  @spec rep(expr(), non_neg_integer(), non_neg_integer() | :infinity, Grammar.IR.Meta.t()) ::
          Rep.t()
  def rep(expr, min, max, meta \\ %Grammar.IR.Meta{}),
    do: %Rep{expr: expr, min: min, max: max, meta: meta}

  @doc """
  Positive lookahead, consumes nothing.

      iex> Grammar.IR.and_pred(Grammar.IR.literal("("))
      %Grammar.IR.AndPred{expr: %Grammar.IR.Literal{value: "("}, meta: %Grammar.IR.Meta{}}

  """
  @spec and_pred(expr(), Grammar.IR.Meta.t()) :: AndPred.t()
  def and_pred(expr, meta \\ %Grammar.IR.Meta{}), do: %AndPred{expr: expr, meta: meta}

  @doc """
  Negative lookahead, consumes nothing.

      iex> Grammar.IR.not_pred(Grammar.IR.literal("\\""))
      %Grammar.IR.NotPred{expr: %Grammar.IR.Literal{value: "\\""}, meta: %Grammar.IR.Meta{}}

  """
  @spec not_pred(expr(), Grammar.IR.Meta.t()) :: NotPred.t()
  def not_pred(expr, meta \\ %Grammar.IR.Meta{}), do: %NotPred{expr: expr, meta: meta}

  @doc """
  Exact string match.

      iex> Grammar.IR.literal("SELECT")
      %Grammar.IR.Literal{value: "SELECT", meta: %Grammar.IR.Meta{}}

  """
  @spec literal(binary(), Grammar.IR.Meta.t()) :: Literal.t()
  def literal(value, meta \\ %Grammar.IR.Meta{}), do: %Literal{value: value, meta: meta}

  @doc """
  Character class, given as a list of inclusive codepoint ranges (a single
  character is `{cp, cp}`).

      iex> Grammar.IR.char_class([{?0, ?9}, {?a, ?f}])
      %Grammar.IR.CharClass{ranges: [{48, 57}, {97, 102}], meta: %Grammar.IR.Meta{}}

  """
  @spec char_class([CharClass.range()], Grammar.IR.Meta.t()) :: CharClass.t()
  def char_class(ranges, meta \\ %Grammar.IR.Meta{}), do: %CharClass{ranges: ranges, meta: meta}

  @doc """
  Matches any single character.

      iex> Grammar.IR.any()
      %Grammar.IR.Any{meta: %Grammar.IR.Meta{}}

  """
  @spec any(Grammar.IR.Meta.t()) :: Any.t()
  def any(meta \\ %Grammar.IR.Meta{}), do: %Any{meta: meta}

  @doc """
  Reference to another rule (or token), by name.

      iex> Grammar.IR.rule_ref(:expr)
      %Grammar.IR.RuleRef{name: :expr, meta: %Grammar.IR.Meta{}}

  """
  @spec rule_ref(atom(), Grammar.IR.Meta.t()) :: RuleRef.t()
  def rule_ref(name, meta \\ %Grammar.IR.Meta{}), do: %RuleRef{name: name, meta: meta}

  @doc """
  Indentation-sensitive block -- `@indent(expr)` when `kind: :indent`
  (must start at a column deeper than the enclosing block), `@samecol(expr)`
  when `kind: :samecol` (must start at exactly the enclosing block's own
  column). Aether's answer to YAML-style layout without a scannerless
  parser having to special-case columns everywhere.

      iex> Grammar.IR.indent(Grammar.IR.rule_ref(:pair), :indent)
      %Grammar.IR.Indent{expr: %Grammar.IR.RuleRef{name: :pair}, kind: :indent, meta: %Grammar.IR.Meta{}}

  """
  @spec indent(expr(), :indent | :samecol, Grammar.IR.Meta.t()) :: Indent.t()
  def indent(expr, kind, meta \\ %Grammar.IR.Meta{}) when kind in [:indent, :samecol],
    do: %Indent{expr: expr, kind: kind, meta: meta}

  @doc """
  Named capture for AST construction.

      iex> Grammar.IR.capture(:op, Grammar.IR.literal("+"))
      %Grammar.IR.Capture{name: :op, expr: %Grammar.IR.Literal{value: "+"}, meta: %Grammar.IR.Meta{}}

  """
  @spec capture(atom(), expr(), Grammar.IR.Meta.t()) :: Capture.t()
  def capture(name, expr, meta \\ %Grammar.IR.Meta{}),
    do: %Capture{name: name, expr: expr, meta: meta}

  @doc """
  `@native(...)` escape hatch: delegates matching to `module.function`
  (an `Ichor.CustomRule` implementation) instead of ordinary combinators.
  `deps` are the only other rules it may call back into; `nullable`/
  `leading` are author-supplied stand-ins for facts `Grammar.Analysis`
  would otherwise compute structurally, since this node's body is opaque.

      iex> Grammar.IR.custom(Prolog.Operators, :parse_infix, [:primary])
      %Grammar.IR.Custom{
        module: Prolog.Operators,
        function: :parse_infix,
        deps: [:primary],
        nullable: false,
        leading: [:primary],
        meta: %Grammar.IR.Meta{}
      }

  """
  @spec custom(module(), atom(), [atom()], boolean(), [atom()], Grammar.IR.Meta.t()) :: Custom.t()
  def custom(
        module,
        function,
        deps,
        nullable \\ false,
        leading \\ nil,
        meta \\ %Grammar.IR.Meta{}
      ) do
    %Custom{
      module: module,
      function: function,
      deps: deps,
      nullable: nullable,
      leading: leading || deps,
      meta: meta
    }
  end

  @doc """
  `@native(...)` escape hatch at *token* position: a token whose entire
  body is `module.function` (an `Ichor.CustomLexeme` implementation).
  `deps` names the rules it may call back into via the re-lex-and-match
  primitive; `nullable` is the same author-supplied stand-in `custom/6`
  uses. No `leading` here -- left-recursion-cycle detection is a
  rule-level concept only.

      iex> Grammar.IR.custom_lexeme(Shell.Heredoc, :scan, [])
      %Grammar.IR.CustomLexeme{
        module: Shell.Heredoc,
        function: :scan,
        deps: [],
        nullable: false,
        meta: %Grammar.IR.Meta{}
      }

  """
  @spec custom_lexeme(module(), atom(), [atom()], boolean(), Grammar.IR.Meta.t()) ::
          CustomLexeme.t()
  def custom_lexeme(module, function, deps, nullable \\ false, meta \\ %Grammar.IR.Meta{}) do
    %CustomLexeme{module: module, function: function, deps: deps, nullable: nullable, meta: meta}
  end

  @doc """
  The immediate sub-expressions of a node, or `[]` for a leaf. Every stage
  that walks a whole grammar (the analysis pass, `Grammar.VM`, native
  codegen) shares this instead of re-deriving "what are this node's
  children" per node type.

      iex> Grammar.IR.children(Grammar.IR.seq([Grammar.IR.literal("a"), Grammar.IR.literal("b")]))
      [%Grammar.IR.Literal{value: "a"}, %Grammar.IR.Literal{value: "b"}]

      iex> Grammar.IR.children(Grammar.IR.any())
      []

  """
  @spec children(expr()) :: [expr()]
  def children(%Seq{exprs: exprs}), do: exprs
  def children(%Choice{exprs: exprs}), do: exprs
  def children(%Star{expr: expr}), do: [expr]
  def children(%Plus{expr: expr}), do: [expr]
  def children(%Opt{expr: expr}), do: [expr]
  def children(%Rep{expr: expr}), do: [expr]
  def children(%AndPred{expr: expr}), do: [expr]
  def children(%NotPred{expr: expr}), do: [expr]
  def children(%Indent{expr: expr}), do: [expr]
  def children(%Capture{expr: expr}), do: [expr]
  def children(%Literal{}), do: []
  def children(%CharClass{}), do: []
  def children(%Any{}), do: []
  def children(%RuleRef{}), do: []
  def children(%Custom{}), do: []
  def children(%CustomLexeme{}), do: []
end
