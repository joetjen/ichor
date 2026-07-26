defmodule Support.MiniMatcher do
  @moduledoc """
  A deliberately small, backtracking PEG matcher over `Grammar.IR` --
  test-only scaffolding, not `Grammar.VM`. It exists for exactly one
  job: proving that `Grammar.Analysis`'s left-recursion rewrite doesn't
  just produce *some* IR, but IR that actually parses real input the
  way the original (naively left-recursive) grammar intended -- a
  left-recursive test grammar compiles to iterative IR and parses
  correctly.
  """

  alias Grammar.IR

  @doc "Matches `root_name` against the whole of `input`, returning true only on a full match."
  @spec matches?(Aether.Grammar.t(), atom(), String.t()) :: boolean()
  def matches?(%Aether.Grammar{} = grammar, root_name, input) do
    defs = Map.merge(grammar.tokens, grammar.rules)

    case match(Map.fetch!(defs, root_name), input, defs) do
      {:ok, ""} -> true
      _ -> false
    end
  end

  defp match(%IR.Seq{exprs: exprs}, input, defs), do: match_seq(exprs, input, defs)

  defp match(%IR.Choice{exprs: exprs}, input, defs) do
    Enum.find_value(exprs, :fail, fn alt ->
      case match(alt, input, defs) do
        {:ok, _} = ok -> ok
        :fail -> nil
      end
    end)
  end

  defp match(%IR.Star{expr: e}, input, defs), do: match_star(e, input, defs)

  defp match(%IR.Plus{expr: e}, input, defs) do
    case match(e, input, defs) do
      {:ok, rest} -> match_star(e, rest, defs)
      :fail -> :fail
    end
  end

  defp match(%IR.Opt{expr: e}, input, defs) do
    case match(e, input, defs) do
      {:ok, rest} -> {:ok, rest}
      :fail -> {:ok, input}
    end
  end

  defp match(%IR.Rep{expr: e, min: min, max: max}, input, defs),
    do: match_rep(e, input, defs, 0, min, max)

  defp match(%IR.AndPred{expr: e}, input, defs) do
    case match(e, input, defs) do
      {:ok, _} -> {:ok, input}
      :fail -> :fail
    end
  end

  defp match(%IR.NotPred{expr: e}, input, defs) do
    case match(e, input, defs) do
      {:ok, _} -> :fail
      :fail -> {:ok, input}
    end
  end

  defp match(%IR.Literal{value: v}, input, _defs) do
    if String.starts_with?(input, v),
      do: {:ok, binary_part(input, byte_size(v), byte_size(input) - byte_size(v))},
      else: :fail
  end

  defp match(%IR.CharClass{ranges: ranges}, input, _defs) do
    case input do
      <<c::utf8, rest::binary>> ->
        if Enum.any?(ranges, fn {a, b} -> c in a..b end), do: {:ok, rest}, else: :fail

      _ ->
        :fail
    end
  end

  defp match(%IR.Any{}, input, _defs) do
    case input do
      <<_c::utf8, rest::binary>> -> {:ok, rest}
      _ -> :fail
    end
  end

  defp match(%IR.RuleRef{name: name}, input, defs), do: match(Map.fetch!(defs, name), input, defs)
  defp match(%IR.Capture{expr: e}, input, defs), do: match(e, input, defs)
  defp match(%IR.Indent{expr: e}, input, defs), do: match(e, input, defs)

  defp match_seq([], input, _defs), do: {:ok, input}

  defp match_seq([e | rest], input, defs) do
    case match(e, input, defs) do
      {:ok, rest_input} -> match_seq(rest, rest_input, defs)
      :fail -> :fail
    end
  end

  defp match_star(e, input, defs) do
    case match(e, input, defs) do
      {:ok, rest} when rest != input -> match_star(e, rest, defs)
      {:ok, _} -> {:ok, input}
      :fail -> {:ok, input}
    end
  end

  defp match_rep(_e, input, _defs, count, _min, max) when max != :infinity and count >= max,
    do: {:ok, input}

  defp match_rep(e, input, defs, count, min, max) do
    case match(e, input, defs) do
      {:ok, rest} when rest != input -> match_rep(e, rest, defs, count + 1, min, max)
      _ when count >= min -> {:ok, input}
      _ -> :fail
    end
  end
end
