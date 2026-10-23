defmodule Grammar.FirstChars do
  @moduledoc """
  The characters a token's match can begin with, worked out from its IR
  when a parser is generated.

  A generated tokenizer does maximal munch: at every position it tries
  every token and keeps the longest match. Most of those tries fail on
  the very first character, so the generated `lex_candidates/2` asks
  each token's start set first (`Grammar.Native.TokenizerCompiler`) and
  tries only the tokens that can begin with the next character.

  **Too much, never too little.** Where a start set cannot be told
  exactly -- any character (`.`), a `@native(...)` token, a token that
  reaches itself again before consuming anything -- the answer is
  `:any`, and the token is always tried. A start set that holds a
  character the token cannot really begin with only costs a try; one
  that missed a character would change which token wins. Only the
  characters a *non-empty* match can begin with count: a zero-width
  match never wins maximal munch.
  """

  alias Grammar.IR

  @typedoc "Sorted, merged `{lo, hi}` codepoint ranges, or `:any`."
  @type t :: {:ranges, [{non_neg_integer(), non_neg_integer()}]} | :any

  @doc """
  The start set of token `name`, whose body and every token it refers to
  are in `tokens`.

      iex> Grammar.FirstChars.of(%{KW: Grammar.IR.literal("let")}, :KW)
      {:ranges, [{?l, ?l}]}

  """
  @spec of(%{atom() => IR.expr()}, atom()) :: t()
  def of(tokens, name) do
    case first(IR.rule_ref(name), tokens, %{}) do
      :any -> :any
      ranges -> {:ranges, merged(Enum.sort(ranges))}
    end
  end

  # What `ir` can begin with -- a list of ranges, or `:any` -- with the
  # tokens being expanded on the way in `visiting`, so a cycle is `:any`.
  defp first(%IR.Literal{value: ""}, _tokens, _visiting), do: []

  defp first(%IR.Literal{value: <<c::utf8, _::binary>>}, _tokens, _visiting), do: [{c, c}]
  defp first(%IR.CharClass{ranges: ranges}, _tokens, _visiting), do: ranges

  defp first(%IR.RuleRef{name: name}, tokens, visiting) do
    with false <- Map.has_key?(visiting, name),
         {:ok, body} <- Map.fetch(tokens, name) do
      first(body, tokens, Map.put(visiting, name, true))
    else
      _cycle_or_unknown -> :any
    end
  end

  defp first(%IR.Seq{exprs: exprs}, tokens, visiting), do: sequence(exprs, tokens, visiting, [])

  defp first(%IR.Choice{exprs: exprs}, tokens, visiting),
    do: Enum.reduce(exprs, [], &union(first(&1, tokens, visiting), &2))

  defp first(%IR.Rep{max: 0}, _tokens, _visiting), do: []

  defp first(%{__struct__: kind, expr: expr}, tokens, visiting)
       when kind in [IR.Star, IR.Plus, IR.Opt, IR.Rep, IR.Capture],
       do: first(expr, tokens, visiting)

  defp first(%{__struct__: kind}, _tokens, _visiting) when kind in [IR.AndPred, IR.NotPred],
    do: []

  defp first(_any_or_unknown, _tokens, _visiting), do: :any

  # A sequence begins with its first element, and with the next one too
  # for as long as the elements before it can match nothing.
  defp sequence([], _tokens, _visiting, acc), do: acc

  defp sequence([expr | rest], tokens, visiting, acc) do
    acc = union(first(expr, tokens, visiting), acc)

    if nullable?(expr, tokens, visiting),
      do: sequence(rest, tokens, visiting, acc),
      else: acc
  end

  # Whether `ir` can match without consuming anything. Unknown nodes and
  # cycles say yes: that only lets a sequence look further, adding to its
  # start set, never taking from it.
  defp nullable?(%IR.Literal{value: value}, _tokens, _visiting), do: value == ""
  defp nullable?(%IR.CharClass{}, _tokens, _visiting), do: false
  defp nullable?(%IR.Any{}, _tokens, _visiting), do: false

  defp nullable?(%IR.RuleRef{name: name}, tokens, visiting) do
    with false <- Map.has_key?(visiting, name),
         {:ok, body} <- Map.fetch(tokens, name) do
      nullable?(body, tokens, Map.put(visiting, name, true))
    else
      _cycle_or_unknown -> true
    end
  end

  defp nullable?(%IR.Seq{exprs: exprs}, tokens, visiting),
    do: Enum.all?(exprs, &nullable?(&1, tokens, visiting))

  defp nullable?(%IR.Choice{exprs: exprs}, tokens, visiting),
    do: Enum.any?(exprs, &nullable?(&1, tokens, visiting))

  defp nullable?(%IR.Plus{expr: expr}, tokens, visiting), do: nullable?(expr, tokens, visiting)

  defp nullable?(%IR.Rep{expr: expr, min: min}, tokens, visiting),
    do: min == 0 or nullable?(expr, tokens, visiting)

  defp nullable?(%IR.Capture{expr: expr}, tokens, visiting), do: nullable?(expr, tokens, visiting)
  defp nullable?(_star_opt_predicate_or_unknown, _tokens, _visiting), do: true

  defp union(:any, _ranges), do: :any
  defp union(_ranges, :any), do: :any
  defp union(more, ranges), do: more ++ ranges

  # Sorted ranges with every overlapping or adjacent pair joined into one.
  defp merged([{lo1, hi1}, {lo2, hi2} | rest]) when lo2 <= hi1 + 1,
    do: merged([{lo1, max(hi1, hi2)} | rest])

  defp merged([range | rest]), do: [range | merged(rest)]
  defp merged([]), do: []
end
