defmodule Grammar.Analysis do
  @moduledoc """
  The analysis pass between a front-end (`Aether.Parser`, or one of the
  ABNF/BNF/EBNF/PEG importers) and either backend (`Grammar.VM` or native
  codegen):

    - **reference checks** -- every `RuleRef` must name a declared token or
      rule; checked first, since the other passes assume a valid namespace.
    - **left-recursion rewrite** -- a rule that references itself as its
      own leftmost derivation is rewritten from `A := A op b | base` into
      the iterative `A := base (op b)*`, the standard PEG/packrat
      transform. Only *direct* self-recursion through a bare (uncaptured)
      leading reference is rewritten automatically; anything else
      (indirect cycles through other rules, or a self-reference buried
      under a capture) is reported as an error instead of guessed at.
    - **possibly-empty-match repetition detection** -- `Star`/`Plus`
      wrapping an expression that can match the empty string never
      terminates; flagged as an error, not just a lint, since it's a real
      runtime hang, not a style nit.
    - **duplicate-alternative lint** -- two structurally identical
      alternatives in the same `Choice` are dead code under PEG's
      first-match-wins semantics -- the second can never be reached.

  Predefined-token override-ordering validation is already enforced by
  `Aether.Parser` itself, as it happens -- it's entirely about Aether's own
  five predefined tokens (`DIGIT`/`ALPHA`/`ALNUM`/`SPACE`/`HEX`), so it
  doesn't generalize to other front-ends the way the checks above do, and
  isn't repeated here.
  """

  alias Grammar.IR
  alias Ichor.Error

  @doc """
  Runs every check above against `grammar`, returning the grammar with
  direct left recursion rewritten to its iterative form, or every error
  found (not just the first -- a grammar author fixing errors one at a
  time via single-error feedback is slower than seeing everything at
  once).
  """
  @spec run(Aether.Grammar.t()) :: {:ok, Aether.Grammar.t()} | {:error, [Error.t()]}
  def run(%Aether.Grammar{} = grammar) do
    all_defs = Map.merge(grammar.tokens, grammar.rules)

    case reference_errors(grammar, all_defs) do
      [] -> analyze(grammar, all_defs)
      errors -> {:error, errors}
    end
  end

  defp analyze(grammar, all_defs) do
    nullable_before = compute_nullable(all_defs)

    case rewrite_left_recursion(grammar, all_defs, nullable_before) do
      {:ok, rewritten_defs} ->
        finish(grammar, rewritten_defs)

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp finish(grammar, all_defs) do
    always_empty = compute_always_empty(all_defs)

    errors =
      empty_repetition_errors(grammar, all_defs, always_empty) ++
        duplicate_alternative_errors(grammar, all_defs)

    case errors do
      [] -> {:ok, split_back(grammar, all_defs)}
      errors -> {:error, errors}
    end
  end

  defp split_back(grammar, all_defs) do
    tokens = Map.new(Map.keys(grammar.tokens), &{&1, Map.fetch!(all_defs, &1)})
    rules = Map.new(Map.keys(grammar.rules), &{&1, Map.fetch!(all_defs, &1)})
    %{grammar | tokens: tokens, rules: rules}
  end

  # ---- error construction ----------------------------------------------

  defp error(grammar, ir, message) do
    {line, col} =
      case first_span(ir) do
        {line, col, _len} -> {line, col}
        nil -> {nil, nil}
      end

    Error.new(
      message: message,
      stage: :analysis,
      file: grammar.file,
      line: line,
      column: col,
      source: grammar.source
    )
  end

  defp first_span(%{meta: %IR.Meta{source_span: span}}) when not is_nil(span), do: span

  defp first_span(ir) do
    ir
    |> IR.children()
    |> Enum.find_value(&first_span/1)
  end

  # ---- reference checks --------------------------------------------------

  defp reference_errors(grammar, all_defs) do
    names = Map.keys(all_defs) |> MapSet.new()

    Enum.flat_map(all_defs, fn {_owner, ir} ->
      collect_dangling_refs(ir, names, grammar)
    end)
  end

  defp collect_dangling_refs(%IR.RuleRef{name: name} = ref, names, grammar) do
    if MapSet.member?(names, name) do
      []
    else
      [error(grammar, ref, "reference to undefined token or rule #{inspect(name)}")]
    end
  end

  defp collect_dangling_refs(ir, names, grammar) do
    Enum.flat_map(IR.children(ir), &collect_dangling_refs(&1, names, grammar))
  end

  # ---- nullability: "CAN this match empty" -- used by the left-recursion
  # rewrite's "does the remainder make progress" check (a remainder that
  # can sometimes match empty would make the rewritten Star loop forever
  # on that input, so the rewrite must reject it). ------------------------

  defp compute_nullable(all_defs) do
    fixpoint(&nullable?/2, MapSet.new(), all_defs)
  end

  defp fixpoint(prop, set, all_defs) do
    next =
      Enum.reduce(all_defs, set, fn {name, ir}, acc ->
        if prop.(ir, set), do: MapSet.put(acc, name), else: acc
      end)

    if MapSet.equal?(next, set), do: set, else: fixpoint(prop, next, all_defs)
  end

  defp nullable?(%IR.Seq{exprs: exprs}, n), do: Enum.all?(exprs, &nullable?(&1, n))
  defp nullable?(%IR.Choice{exprs: exprs}, n), do: Enum.any?(exprs, &nullable?(&1, n))
  defp nullable?(%IR.Star{}, _n), do: true
  defp nullable?(%IR.Plus{expr: e}, n), do: nullable?(e, n)
  defp nullable?(%IR.Opt{}, _n), do: true
  defp nullable?(%IR.Rep{expr: e, min: min}, n), do: min == 0 or nullable?(e, n)
  defp nullable?(%IR.AndPred{}, _n), do: true
  defp nullable?(%IR.NotPred{}, _n), do: true
  defp nullable?(%IR.Literal{value: ""}, _n), do: true
  defp nullable?(%IR.Literal{}, _n), do: false
  defp nullable?(%IR.CharClass{}, _n), do: false
  defp nullable?(%IR.Any{}, _n), do: false
  defp nullable?(%IR.RuleRef{name: name}, n), do: MapSet.member?(n, name)
  defp nullable?(%IR.Indent{expr: e}, n), do: nullable?(e, n)
  defp nullable?(%IR.Capture{expr: e}, n), do: nullable?(e, n)

  # ---- "always empty": UNCONDITIONALLY zero-width, no matter the input --
  # this is the hazard the repetition check below exists for ("X{0}, or
  # any token that always matches empty, wrapped in */+ loops forever").
  # Deliberately stricter
  # than `nullable?/2` above: a merely-nullable skip token like
  # `SPACE := [ \t]*` is completely ordinary and safe to auto-splice as
  # `SPACE*` everywhere (ordinary Star/Plus implementations stop as soon
  # as an iteration fails to advance) -- it's specifically an expression
  # that can *never* consume anything, at all, that turns a wrapping
  # repetition into a real infinite loop.

  defp compute_always_empty(all_defs) do
    fixpoint(&always_empty?/2, MapSet.new(), all_defs)
  end

  defp always_empty?(%IR.Seq{exprs: exprs}, n), do: Enum.all?(exprs, &always_empty?(&1, n))
  defp always_empty?(%IR.Choice{exprs: exprs}, n), do: Enum.all?(exprs, &always_empty?(&1, n))
  defp always_empty?(%IR.Star{expr: e}, n), do: always_empty?(e, n)
  defp always_empty?(%IR.Plus{expr: e}, n), do: always_empty?(e, n)
  defp always_empty?(%IR.Opt{expr: e}, n), do: always_empty?(e, n)
  defp always_empty?(%IR.Rep{max: 0}, _n), do: true
  defp always_empty?(%IR.Rep{expr: e}, n), do: always_empty?(e, n)
  defp always_empty?(%IR.AndPred{}, _n), do: true
  defp always_empty?(%IR.NotPred{}, _n), do: true
  defp always_empty?(%IR.Literal{value: ""}, _n), do: true
  defp always_empty?(%IR.Literal{}, _n), do: false
  defp always_empty?(%IR.CharClass{}, _n), do: false
  defp always_empty?(%IR.Any{}, _n), do: false
  defp always_empty?(%IR.RuleRef{name: name}, n), do: MapSet.member?(n, name)
  defp always_empty?(%IR.Indent{expr: e}, n), do: always_empty?(e, n)
  defp always_empty?(%IR.Capture{expr: e}, n), do: always_empty?(e, n)

  # ---- left recursion: detection (sound, capture-transparent) -----------

  # The set of names that could be invoked at the very start of `ir`'s
  # derivation -- i.e. before any input is consumed. Used to build the
  # "who calls whom leftmost" graph that left recursion is a cycle in.
  # Capture-transparent so detection doesn't miss a hazard just because
  # the self-reference happens to be captured (the rewrite below is
  # stricter, and falls back to an error for exactly that gap).
  defp leading_refs(%IR.Seq{exprs: [first | _]}), do: leading_refs(first)
  defp leading_refs(%IR.Seq{exprs: []}), do: MapSet.new()

  defp leading_refs(%IR.Choice{exprs: exprs}),
    do: Enum.reduce(exprs, MapSet.new(), &MapSet.union(leading_refs(&1), &2))

  defp leading_refs(%IR.Star{expr: e}), do: leading_refs(e)
  defp leading_refs(%IR.Plus{expr: e}), do: leading_refs(e)
  defp leading_refs(%IR.Opt{expr: e}), do: leading_refs(e)
  defp leading_refs(%IR.Rep{expr: e}), do: leading_refs(e)
  defp leading_refs(%IR.AndPred{expr: e}), do: leading_refs(e)
  defp leading_refs(%IR.NotPred{expr: e}), do: leading_refs(e)
  defp leading_refs(%IR.Indent{expr: e}), do: leading_refs(e)
  defp leading_refs(%IR.Capture{expr: e}), do: leading_refs(e)
  defp leading_refs(%IR.RuleRef{name: name}), do: MapSet.new([name])
  defp leading_refs(%IR.Literal{}), do: MapSet.new()
  defp leading_refs(%IR.CharClass{}), do: MapSet.new()
  defp leading_refs(%IR.Any{}), do: MapSet.new()

  defp reachable(name, graph), do: do_reachable([name], graph, MapSet.new())

  defp do_reachable([], _graph, acc), do: acc

  defp do_reachable([name | rest], graph, acc) do
    next = graph |> Map.get(name, MapSet.new()) |> MapSet.difference(acc)
    do_reachable(MapSet.to_list(next) ++ rest, graph, MapSet.union(acc, next))
  end

  # ---- left recursion: automatic rewrite for the direct case ------------

  defp rewrite_left_recursion(grammar, all_defs, nullable) do
    graph = Map.new(all_defs, fn {name, ir} -> {name, leading_refs(ir)} end)

    {defs, errors} =
      Enum.reduce(all_defs, {all_defs, []}, fn {name, _ir}, {defs, errors} ->
        case apply_rewrite(name, graph, nullable, grammar, defs) do
          {:ok, new_defs} -> {new_defs, errors}
          {:error, error} -> {defs, [error | errors]}
        end
      end)

    case Enum.reverse(errors) do
      [] -> {:ok, defs}
      errors -> {:error, errors}
    end
  end

  defp apply_rewrite(name, graph, nullable, grammar, defs) do
    if MapSet.member?(reachable(name, graph), name) do
      ir = Map.fetch!(defs, name)

      if MapSet.member?(Map.fetch!(graph, name), name) do
        case rewrite_direct(name, ir, nullable) do
          {:ok, new_ir} -> {:ok, Map.put(defs, name, new_ir)}
          {:error, reason} -> {:error, error(grammar, ir, "#{name} is left-recursive: #{reason}")}
        end
      else
        {:error,
         error(
           grammar,
           ir,
           "#{name} is left-recursive through one or more other rules -- automatic rewriting only supports a direct, bare leading self-reference; restructure it by hand"
         )}
      end
    else
      {:ok, defs}
    end
  end

  defp rewrite_direct(name, ir, nullable) do
    alts = choice_alternatives(ir)
    {recursive, base} = Enum.split_with(alts, &(classify_alt(&1, name) != :base))

    cond do
      base == [] ->
        {:error, "has no non-recursive alternative to serve as a base case"}

      recursive == [] ->
        {:error,
         "the self-reference isn't a direct, bare leading reference (e.g. it's wrapped in a capture) -- only that shape is automatically rewritten"}

      true ->
        with {:ok, remainders} <- collect_remainders(recursive, name) do
          if Enum.any?(remainders, &nullable?(&1, nullable)) do
            {:error,
             "rewriting it would produce an infinite loop -- the part after the self-reference can match empty"}
          else
            {:ok, IR.seq([unwrap_choice(base), IR.star(unwrap_choice(remainders))])}
          end
        end
    end
  end

  defp collect_remainders(alts, name) do
    Enum.reduce_while(alts, {:ok, []}, fn alt, {:ok, acc} ->
      case classify_alt(alt, name) do
        {:recursive, nil} ->
          {:halt,
           {:error,
            "a left-recursive alternative must consume something after the self-reference, or it never terminates"}}

        {:recursive, remainder} ->
          {:cont, {:ok, [remainder | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp choice_alternatives(%IR.Choice{exprs: exprs}), do: exprs
  defp choice_alternatives(other), do: [other]

  defp unwrap_choice([one]), do: one
  defp unwrap_choice(many), do: IR.choice(many)

  defp unwrap_seq([]), do: nil
  defp unwrap_seq([one]), do: one
  defp unwrap_seq(many), do: IR.seq(many)

  defp classify_alt(%IR.RuleRef{name: name}, name), do: {:recursive, nil}

  defp classify_alt(%IR.Seq{exprs: [%IR.RuleRef{name: name} | rest]}, name),
    do: {:recursive, unwrap_seq(rest)}

  defp classify_alt(_alt, _name), do: :base

  # ---- possibly-empty-match repetition ------------------------------------

  defp empty_repetition_errors(grammar, all_defs, always_empty) do
    Enum.flat_map(all_defs, fn {_owner, ir} ->
      collect_empty_repetitions(ir, always_empty, grammar)
    end)
  end

  defp collect_empty_repetitions(%IR.Star{expr: e} = star, always_empty, grammar) do
    if always_empty?(e, always_empty) do
      [error(grammar, star, "repeats an unconditionally-empty match -- this never terminates")]
    else
      []
    end ++ collect_empty_repetitions(e, always_empty, grammar)
  end

  defp collect_empty_repetitions(%IR.Plus{expr: e} = plus, always_empty, grammar) do
    if always_empty?(e, always_empty) do
      [error(grammar, plus, "repeats an unconditionally-empty match -- this never terminates")]
    else
      []
    end ++ collect_empty_repetitions(e, always_empty, grammar)
  end

  defp collect_empty_repetitions(ir, always_empty, grammar) do
    Enum.flat_map(IR.children(ir), &collect_empty_repetitions(&1, always_empty, grammar))
  end

  # ---- duplicate alternatives (dead code under PEG's first-match-wins) --

  defp duplicate_alternative_errors(grammar, all_defs) do
    Enum.flat_map(all_defs, fn {_owner, ir} -> collect_duplicate_alternatives(ir, grammar) end)
  end

  defp collect_duplicate_alternatives(%IR.Choice{exprs: exprs}, grammar) do
    duplicates_from_children =
      Enum.flat_map(exprs, &collect_duplicate_alternatives(&1, grammar))

    normalized = Enum.map(exprs, &strip_meta/1)

    {_seen, dup_indices} =
      normalized
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {norm, idx}, {seen, dups} ->
        if norm in seen, do: {seen, [idx | dups]}, else: {[norm | seen], dups}
      end)

    this_choice_errors =
      dup_indices
      |> Enum.reverse()
      |> Enum.map(fn idx ->
        error(
          grammar,
          Enum.at(exprs, idx),
          "duplicates an earlier alternative in the same choice -- unreachable under PEG's first-match-wins rule"
        )
      end)

    this_choice_errors ++ duplicates_from_children
  end

  defp collect_duplicate_alternatives(ir, grammar) do
    Enum.flat_map(IR.children(ir), &collect_duplicate_alternatives(&1, grammar))
  end

  defp strip_meta(%IR.Seq{exprs: exprs}), do: %IR.Seq{exprs: Enum.map(exprs, &strip_meta/1)}
  defp strip_meta(%IR.Choice{exprs: exprs}), do: %IR.Choice{exprs: Enum.map(exprs, &strip_meta/1)}
  defp strip_meta(%IR.Star{expr: e}), do: %IR.Star{expr: strip_meta(e)}
  defp strip_meta(%IR.Plus{expr: e}), do: %IR.Plus{expr: strip_meta(e)}
  defp strip_meta(%IR.Opt{expr: e}), do: %IR.Opt{expr: strip_meta(e)}

  defp strip_meta(%IR.Rep{expr: e, min: mn, max: mx}),
    do: %IR.Rep{expr: strip_meta(e), min: mn, max: mx}

  defp strip_meta(%IR.AndPred{expr: e}), do: %IR.AndPred{expr: strip_meta(e)}
  defp strip_meta(%IR.NotPred{expr: e}), do: %IR.NotPred{expr: strip_meta(e)}
  defp strip_meta(%IR.Literal{value: v}), do: %IR.Literal{value: v}
  defp strip_meta(%IR.CharClass{ranges: r}), do: %IR.CharClass{ranges: r}
  defp strip_meta(%IR.Any{}), do: %IR.Any{}
  defp strip_meta(%IR.RuleRef{name: n}), do: %IR.RuleRef{name: n}
  defp strip_meta(%IR.Indent{expr: e, kind: k}), do: %IR.Indent{expr: strip_meta(e), kind: k}
  defp strip_meta(%IR.Capture{name: n, expr: e}), do: %IR.Capture{name: n, expr: strip_meta(e)}
end
