defmodule Grammar.VM.RuleCompiler do
  @moduledoc """
  Compiles every rule in a grammar into one linked `Grammar.VM.Program`,
  run by `Grammar.VM.TokenInterpreter` against the lexer's token stream
  (never against raw characters -- Aether's two-stage Lexer -> Parser
  split). A `RuleRef` compiles to `{:token, name}` (consume one stream
  token of that type) when it names a token, or `{:call, name}` (jump
  into that rule's own compiled code) when it names another rule -- the
  two are otherwise indistinguishable in the IR, so the grammar's own
  token/rule namespaces are what disambiguate.

  `Indent`/`@samecol` read a token's column straight off the stream (the
  lexer already recorded it), rather than tracking columns incrementally
  during parsing.

  Every bare `RuleRef` -- and every `Capture` -- is additionally
  bracketed with `{:cap_start, ...}`/`{:cap_end, name}`, so
  `Grammar.VM.TokenInterpreter` can build the raw capture tree
  `Ichor.Actions` needs: a bare reference is implicitly captured under
  *its own* name (this is what lets a calculator's own
  `handle_rule(:expr, %{op: ops, term: terms}, ctx)` see a `:term` key
  even though `expr`'s grammar never writes `term:term`); an explicit
  `name:expr` additionally captures under the given name. A bare
  reference to an *anonymous* auto-promoted token (an inline literal like
  `"("`, never a name the grammar author chose) gets no implicit capture
  at all: writing a bare
  literal is precisely how a grammar author says "I don't care about
  this," and implicitly capturing it anyway would leak a
  compiler-generated name into every rule that uses one, breaking the
  "exactly one capture passes straight through" default fallback for
  something as simple as `factor := NUMBER | "(" expr ")"`. Explicitly
  naming one (`paren:"("`) still works -- that's a deliberate capture,
  not an implicit one.

  Only a capture whose expression is *directly* a bare `RuleRef` (no
  wrapping `Choice`/`Star`/... in between) dispatches to that rule/token's
  own action on `eval` -- anything else captures the raw matched text
  span instead. That's a deliberate, narrower rule than "figure out the
  one branch that actually matched at runtime": it keeps capture
  semantics decidable from the grammar's static shape, at the cost of not
  dispatching through a capture like `x:(rule_a | rule_b)` -- not needed
  by any of Ichor's own worked-example grammars, and worth revisiting
  only if a real grammar actually needs it.

  `capture_shapes/1` is a separate static pass answering "which capture
  names, for each rule, sit under a `Star`/`Plus`/`Rep` anywhere in that
  rule's body" -- a name captured that way needs a *list* value even when
  it happened to match once, or zero times (an absent key, vs. an empty
  list, isn't something a `Calculator.Actions`-style
  `%{op: ops, factor: factors}` pattern match can tell apart from "this
  rule shape doesn't have that capture at all"). `Ichor.Actions` uses this
  table to normalize the raw capture tree before dispatch.
  """

  alias Grammar.IR
  alias Grammar.VM.{Compiler, Linker}

  @spec compile(Aether.Grammar.t()) :: Grammar.VM.Program.t()
  def compile(grammar) do
    token_names = token_names(grammar)
    anon_tokens = implicit_capture_exclusions(grammar)

    {named_ops, _counter} =
      Enum.reduce(grammar.rules, {[], 0}, fn {name, ir}, {acc, counter} ->
        {ops, counter} = Compiler.compile(ir, counter, &leaf(&1, &2, token_names, anon_tokens))
        {[{name, ops ++ [{:return}]} | acc], counter}
      end)

    Linker.link(Enum.reverse(named_ops))
  end

  # Every name a `RuleRef` can mean a *token* by: both a real
  # `TOKEN := ...` declaration and a `@keywords`/`@refine` reclassification
  # target (which never gets its own declaration -- see
  # `Aether.Grammar.refiner_target_names/1`). Public because
  # `Grammar.Native.RuleCompiler` needs the exact same token/rule split --
  # this determination must not drift between backends.
  @doc false
  @spec token_names(Aether.Grammar.t()) :: MapSet.t(atom())
  def token_names(grammar) do
    MapSet.union(
      MapSet.new(Map.keys(grammar.tokens)),
      Aether.Grammar.refiner_target_names(grammar.refiners)
    )
  end

  # Bare references never get an implicit self-capture when they're
  # compiler-inserted rather than something the grammar author actually
  # wrote: an auto-promoted anonymous literal token, or the grammar's own
  # `@skip` token spliced in between sequence elements -- neither was a
  # deliberate choice to name/capture anything, an explicit `name:expr`
  # still overrides this regardless.
  #
  # Public because `Grammar.Native.RuleCompiler` needs the exact same
  # exclusion set -- this determination must not drift between backends.
  @doc false
  @spec implicit_capture_exclusions(Aether.Grammar.t()) :: MapSet.t(atom())
  def implicit_capture_exclusions(grammar) do
    case grammar.skip do
      nil -> grammar.anon_tokens
      skip -> MapSet.put(grammar.anon_tokens, skip)
    end
  end

  @doc """
  For every rule, the set of capture names that sit under a
  `Star`/`Plus`/`Rep` somewhere in that rule's own body (not descending
  into other rules/tokens it calls).
  """
  @spec capture_shapes(Aether.Grammar.t()) :: %{atom() => MapSet.t(atom())}
  def capture_shapes(grammar) do
    anon_tokens = implicit_capture_exclusions(grammar)

    Map.new(grammar.rules, fn {name, ir} ->
      {name, repeatable_names(ir, false, anon_tokens, MapSet.new())}
    end)
  end

  defp repeatable_names(%IR.Seq{exprs: exprs}, rep?, anon, acc),
    do: Enum.reduce(exprs, acc, &repeatable_names(&1, rep?, anon, &2))

  defp repeatable_names(%IR.Choice{exprs: exprs}, rep?, anon, acc),
    do: Enum.reduce(exprs, acc, &repeatable_names(&1, rep?, anon, &2))

  defp repeatable_names(%IR.Star{expr: e}, _rep?, anon, acc),
    do: repeatable_names(e, true, anon, acc)

  defp repeatable_names(%IR.Plus{expr: e}, _rep?, anon, acc),
    do: repeatable_names(e, true, anon, acc)

  defp repeatable_names(%IR.Rep{expr: e}, _rep?, anon, acc),
    do: repeatable_names(e, true, anon, acc)

  defp repeatable_names(%IR.Opt{expr: e}, rep?, anon, acc),
    do: repeatable_names(e, rep?, anon, acc)

  defp repeatable_names(%IR.AndPred{expr: e}, rep?, anon, acc),
    do: repeatable_names(e, rep?, anon, acc)

  defp repeatable_names(%IR.NotPred{expr: e}, rep?, anon, acc),
    do: repeatable_names(e, rep?, anon, acc)

  defp repeatable_names(%IR.Indent{expr: e}, rep?, anon, acc),
    do: repeatable_names(e, rep?, anon, acc)

  # `name:REF` never produces an implicit self-capture under `REF`'s own
  # name (see `leaf/4`'s matching special case below) -- only `name`
  # itself -- so recursing into the bare `RuleRef` with the same `rep?`
  # would wrongly mark `REF`'s own name repeatable too, purely because it
  # happens to be *referenced* from a repeated position, even though
  # nothing ever captures under that name here. Composite inner
  # expressions (the general clause below) genuinely can contain their
  # own further-nested captures, which do need the recursion.
  defp repeatable_names(%IR.Capture{name: name, expr: %IR.RuleRef{}}, rep?, _anon, acc) do
    if rep?, do: MapSet.put(acc, name), else: acc
  end

  defp repeatable_names(%IR.Capture{name: name, expr: inner}, rep?, anon, acc) do
    acc = if rep?, do: MapSet.put(acc, name), else: acc
    repeatable_names(inner, rep?, anon, acc)
  end

  defp repeatable_names(%IR.RuleRef{name: name}, rep?, anon, acc) do
    if rep? and not MapSet.member?(anon, name), do: MapSet.put(acc, name), else: acc
  end

  defp repeatable_names(_leaf, _rep?, _anon, acc), do: acc

  defp leaf(%IR.RuleRef{name: name}, counter, token_names, anon_tokens) do
    if MapSet.member?(anon_tokens, name) do
      {[{:token, name}], counter}
    else
      {captured_ref(name, name, token_names), counter}
    end
  end

  defp leaf(
         %IR.Capture{name: cap_name, expr: %IR.RuleRef{name: ref_name}},
         counter,
         token_names,
         _anon_tokens
       ) do
    {captured_ref(cap_name, ref_name, token_names), counter}
  end

  # `@native(...)`, bare or explicitly captured: like a bare `RuleRef`'s
  # implicit self-capture, but there's no rule/token name to reuse, so the
  # callback's own `function` name stands in for it.
  defp leaf(
         %IR.Capture{name: cap_name, expr: %IR.Custom{} = custom},
         counter,
         _token_names,
         _anon_tokens
       ) do
    {captured_custom(cap_name, custom), counter}
  end

  defp leaf(%IR.Custom{function: function} = custom, counter, _token_names, _anon_tokens) do
    {captured_custom(function, custom), counter}
  end

  defp leaf(%IR.Capture{name: cap_name, expr: inner}, counter, token_names, anon_tokens) do
    {ops, counter} = Compiler.compile(inner, counter, &leaf(&1, &2, token_names, anon_tokens))
    {[{:cap_start, cap_name, :text, nil}] ++ ops ++ [{:cap_end, cap_name}], counter}
  end

  defp leaf(%IR.Indent{expr: e, kind: :indent}, counter, token_names, anon_tokens) do
    {ops, counter} = Compiler.compile(e, counter, &leaf(&1, &2, token_names, anon_tokens))
    {[{:indent_enter}] ++ ops ++ [{:indent_exit}], counter}
  end

  defp leaf(%IR.Indent{expr: e, kind: :samecol}, counter, token_names, anon_tokens) do
    {ops, counter} = Compiler.compile(e, counter, &leaf(&1, &2, token_names, anon_tokens))
    {[{:samecol_check} | ops], counter}
  end

  defp captured_ref(cap_name, ref_name, token_names) do
    if MapSet.member?(token_names, ref_name) do
      [{:cap_start, cap_name, :token, ref_name}, {:token, ref_name}, {:cap_end, cap_name}]
    else
      [{:cap_start, cap_name, :rule, ref_name}, {:call, ref_name}, {:cap_end, cap_name}]
    end
  end

  defp captured_custom(cap_name, %IR.Custom{module: module, function: function, deps: deps}) do
    [
      {:cap_start, cap_name, :custom, nil},
      {:custom, module, function, deps},
      {:cap_end, cap_name}
    ]
  end
end
