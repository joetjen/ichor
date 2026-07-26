defmodule Grammar.Tokens do
  @moduledoc """
  Token introspection for a compiled `Aether.Grammar` -- the logic behind
  `mix ichor.tokens`. Depends only on the Aether front-end's output
  (`token_order`/`tokens`/`anon_tokens`), not the analysis pass or either
  backend, so it works on any grammar that parses, even one the analysis
  pass would otherwise reject.
  """

  alias Grammar.IR.{AndPred, Any, Capture, CharClass, Choice, Indent, Literal}
  alias Grammar.IR.{NotPred, Opt, Plus, Rep, RuleRef, Seq, Star}

  @predefined_names ~w(DIGIT ALPHA ALNUM SPACE HEX)a

  @type kind :: :declared | :anonymous | :predefined

  @type entry :: %{name: atom(), kind: kind(), pattern: String.t()}

  @doc """
  Every token in `grammar`, in `token_order` (the same order the Lexer's
  maximal-munch tie-break uses) -- user-declared tokens, tokens
  auto-promoted from an inline rule literal (`kind: :anonymous`), and the
  five always-present predefined tokens (`kind: :predefined`), whether
  overridden or left at their default.
  """
  @spec list(Aether.Grammar.t()) :: [entry()]
  def list(%Aether.Grammar{token_order: order, tokens: tokens, anon_tokens: anon}) do
    Enum.map(order, fn name ->
      %{name: name, kind: kind(name, anon), pattern: describe(Map.fetch!(tokens, name))}
    end)
  end

  defp kind(name, anon) do
    cond do
      MapSet.member?(anon, name) -> :anonymous
      name in @predefined_names -> :predefined
      true -> :declared
    end
  end

  @doc """
  Renders a `Grammar.IR` expression as a compact PEG-like pattern string,
  for display only -- not a serialization format, and not fed back into
  the parser anywhere.

      iex> Grammar.Tokens.describe(Grammar.IR.literal("SELECT"))
      "\\"SELECT\\""

      iex> Grammar.Tokens.describe(Grammar.IR.char_class([{?0, ?9}, {?a, ?f}]))
      "[0-9a-f]"

      iex> digit = Grammar.IR.char_class([{?0, ?9}])
      iex> Grammar.Tokens.describe(Grammar.IR.seq([Grammar.IR.plus(digit), Grammar.IR.opt(Grammar.IR.literal("."))]))
      "[0-9]+ \\".\\"?"

      iex> Grammar.Tokens.describe(Grammar.IR.choice([Grammar.IR.literal("+"), Grammar.IR.literal("-")]))
      "\\"+\\" | \\"-\\""

  """
  @spec describe(Grammar.IR.expr()) :: String.t()
  def describe(expr), do: render(expr, 0)

  # Precedence climbing: each node renders itself and its own precedence;
  # a child is parenthesized only when its precedence is lower than what
  # the parent requires, so e.g. `(a | b)*` keeps its parens but `a b*`
  # (seq around a postfix child) never gains redundant ones.
  # choice(0) < seq(1) < predicate(2) < postfix(3) < atom(4)
  defp render(expr, min_prec) do
    {str, prec} = render(expr)
    if prec < min_prec, do: "(#{str})", else: str
  end

  defp render(%Seq{exprs: exprs}), do: {Enum.map_join(exprs, " ", &render(&1, 1)), 1}
  defp render(%Choice{exprs: exprs}), do: {Enum.map_join(exprs, " | ", &render(&1, 0)), 0}
  defp render(%Star{expr: e}), do: {render(e, 3) <> "*", 3}
  defp render(%Plus{expr: e}), do: {render(e, 3) <> "+", 3}
  defp render(%Opt{expr: e}), do: {render(e, 3) <> "?", 3}
  defp render(%Rep{expr: e, min: min, max: max}), do: {render(e, 3) <> rep_suffix(min, max), 3}
  defp render(%AndPred{expr: e}), do: {"&" <> render(e, 2), 2}
  defp render(%NotPred{expr: e}), do: {"!" <> render(e, 2), 2}
  defp render(%Literal{value: v}), do: {inspect(v), 4}
  defp render(%CharClass{ranges: ranges}), do: {class_str(ranges), 4}
  defp render(%Any{}), do: {".", 4}
  defp render(%RuleRef{name: n}), do: {to_string(n), 4}
  defp render(%Indent{expr: e, kind: k}), do: {"@#{k}(#{render(e, 0)})", 4}
  defp render(%Capture{name: n, expr: e}), do: {"#{n}:#{render(e, 3)}", 4}

  defp rep_suffix(n, n), do: "{#{n}}"
  defp rep_suffix(min, :infinity), do: "{#{min},}"
  defp rep_suffix(min, max), do: "{#{min},#{max}}"

  defp class_str(ranges), do: "[" <> Enum.map_join(ranges, "", &range_piece/1) <> "]"

  defp range_piece({lo, lo}), do: class_char(lo)
  defp range_piece({lo, hi}), do: class_char(lo) <> "-" <> class_char(hi)

  defp class_char(cp) do
    char = <<cp::utf8>>

    cond do
      char in ["]", "^", "-", "\\"] -> "\\" <> char
      cp in 0x20..0x7E -> char
      true -> "\\u{" <> Integer.to_string(cp, 16) <> "}"
    end
  end
end
