defmodule Support.IRStrip do
  @moduledoc """
  Strips `Grammar.IR` source-span metadata for structural comparison --
  shared by `Regex.ActionsTest` (VM backend) and any native-backend
  parity test comparing a regex-parsed `Grammar.IR` tree against
  `Aether.Parser`'s own `/pattern/` desugaring, since source spans
  naturally differ between two independent parses of the same text.
  """

  alias Grammar.IR

  @spec strip(IR.expr()) :: IR.expr()
  def strip(%IR.Seq{exprs: exprs}), do: IR.seq(Enum.map(exprs, &strip/1))
  def strip(%IR.Choice{exprs: exprs}), do: IR.choice(Enum.map(exprs, &strip/1))
  def strip(%IR.Star{expr: e}), do: IR.star(strip(e))
  def strip(%IR.Plus{expr: e}), do: IR.plus(strip(e))
  def strip(%IR.Opt{expr: e}), do: IR.opt(strip(e))
  def strip(%IR.Rep{expr: e, min: min, max: max}), do: IR.rep(strip(e), min, max)
  def strip(%IR.AndPred{expr: e}), do: IR.and_pred(strip(e))
  def strip(%IR.NotPred{expr: e}), do: IR.not_pred(strip(e))
  def strip(%IR.Indent{expr: e, kind: k}), do: IR.indent(strip(e), k)
  def strip(%IR.Capture{expr: e, name: n}), do: IR.capture(n, strip(e))
  def strip(%IR.Literal{value: v}), do: IR.literal(v)
  def strip(%IR.CharClass{ranges: r}), do: IR.char_class(r)
  def strip(%IR.Any{}), do: IR.any()
  def strip(%IR.RuleRef{name: n}), do: IR.rule_ref(n)
end
