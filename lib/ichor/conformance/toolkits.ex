defmodule Ichor.Conformance.Toolkits do
  @moduledoc """
  This implementation's answers to the Ichor Conformance Suite's toolkit
  cases: `Ichor.Toolkit.Pratt`, `Ichor.Backtrack.Bindings`,
  `Ichor.Backtrack.Tree` and `Ichor.Toolkit.TermWalk`, each run on data a
  case gives and answering data.

  **The callbacks are the suite's, not a grammar's.** Each toolkit takes
  callbacks or a term module, which are host code; every adapter
  supplies the same small standard set, so what is compared is the
  toolkit's own behaviour:

  - **A term** is `{:var, name}` for a variable, `{:term, functor,
    args}` for a compound, and anything else for an atomic term
    (`Ichor.Conformance.Toolkits.Term`).
  - **Pratt** reads a list of tokens. An operand is one token that is not
    an operator; a node is `{fixity, op, operands...}`; an operand can
    start where the next token is an operand or a prefix operator.

  The operations:

  - `"pratt"` -- `"operators"` (op => `%{prefix: prec, infix: [prec,
    assoc], postfix: prec}`) and `"tokens"`; answers `"tree"`, or
    `"error"`: `:fail`, or `{:"left-over", index}` of the first token
    not read.
  - `"unify"` -- `"left"`, `"right"`, `"occurs-check"`; answers
    `"result"`: the bindings it made, each variable to what it was bound
    to, or `:fail`.
  - `"solve"` -- `"goal"`: `:succeed`, `:fail`, `{:unify, a, b}`,
    `{:and, g, g}`, `{:or, g, g}`, `{:once, g}`; answers `"solutions"`:
    every solution's bindings, in order.
  - `"walk"` -- `"term"` and `"walk"`: `:visit`, the terms visited in
    order, or `{:rename, %{from => to}}`, the term with those functors
    renamed; answers `"result"`.
  """

  alias Ichor.Backtrack.{Bindings, Tree}
  alias Ichor.Conformance.Toolkits.Term
  alias Ichor.Toolkit.{Pratt, TermWalk}

  defmodule Term do
    @moduledoc """
    The suite's terms, as `Ichor.Backtrack.Term` sees them: `{:var,
    name}`, `{:term, functor, args}`, or an atomic value.
    """
    @behaviour Ichor.Backtrack.Term

    @impl true
    def variable?(term), do: match?({:var, _}, term)
    @impl true
    def var_id({:var, name}), do: name
    @impl true
    def compound?(term), do: match?({:term, _, _}, term)
    @impl true
    def deconstruct({:term, functor, args}), do: {functor, args}
    @impl true
    def reconstruct(functor, args), do: {:term, functor, args}
  end

  @doc "The outcome of one toolkit case, its inputs already decoded."
  @spec outcome(String.t(), map()) :: map()
  def outcome("pratt", %{"operators" => operators, "tokens" => tokens}) do
    table = table(operators)
    stream = List.to_tuple(tokens)

    case Pratt.parse(table, 0, callbacks(table, stream)) do
      {:ok, pos, tree} when pos == tuple_size(stream) -> %{"tree" => tree}
      {:ok, pos, _tree} -> %{"error" => {:"left-over", pos}}
      :fail -> %{"error" => :fail}
    end
  end

  def outcome("unify", %{"left" => left, "right" => right, "occurs-check" => occurs?}) do
    unify = if occurs?, do: &Bindings.unify_occurs_check/4, else: &Bindings.unify/4

    case unify.(Term, Bindings.new(), left, right) do
      {:ok, bindings} -> %{"result" => bindings}
      :fail -> %{"result" => :fail}
    end
  end

  def outcome("solve", %{"goal" => goal}),
    do: %{"solutions" => goal |> goal() |> apply([Bindings.new()]) |> all()}

  def outcome("walk", %{"term" => term, "walk" => :visit}),
    do: %{"result" => Term |> TermWalk.fold(term, [], &[&1 | &2]) |> Enum.reverse()}

  def outcome("walk", %{"term" => term, "walk" => {:rename, names}}) do
    renamed =
      TermWalk.rewrite(Term, term, fn
        {:term, functor, args} -> {:term, Map.get(names, functor, functor), args}
        other -> other
      end)

    %{"result" => renamed}
  end

  # ---- pratt -----------------------------------------------------------

  defp table(operators) do
    Enum.reduce(operators, Pratt.new(), fn {op, fixities}, table ->
      Enum.reduce(fixities, table, fn
        {:prefix, prec}, t -> Pratt.prefix(t, op, prec)
        {:infix, [prec, assoc]}, t -> Pratt.infix(t, op, prec, assoc)
        {:postfix, prec}, t -> Pratt.postfix(t, op, prec)
      end)
    end)
  end

  # Positions are token indexes. An operand is one token that is not an
  # operator; one can start where the next token is an operand or a
  # prefix operator.
  defp callbacks(table, stream) do
    at = fn pos -> if pos < tuple_size(stream), do: elem(stream, pos) end

    %{
      peek_op: fn pos ->
        token = at.(pos)
        if Map.has_key?(table, token), do: {token, pos + 1}
      end,
      parse_primary: fn pos ->
        token = at.(pos)
        if is_nil(token) or Map.has_key?(table, token), do: :fail, else: {:ok, pos + 1, token}
      end,
      build: fn fixity, op, operands -> List.to_tuple([fixity, op | operands]) end,
      can_start_operand?: fn pos ->
        token = at.(pos)

        not is_nil(token) and
          (not Map.has_key?(table, token) or Map.has_key?(table[token], :prefix))
      end
    }
  end

  # ---- solve -----------------------------------------------------------

  defp goal(:succeed), do: Tree.unit()
  defp goal(:fail), do: Tree.fail()
  defp goal({:and, a, b}), do: Tree.conjunction(goal(a), goal(b))
  defp goal({:or, a, b}), do: Tree.disjunction(goal(a), goal(b))
  defp goal({:once, g}), do: Tree.once(goal(g))

  defp goal({:unify, a, b}) do
    fn bindings ->
      case Bindings.unify(Term, bindings, a, b) do
        {:ok, extended} -> Tree.of_one(extended)
        :fail -> Tree.empty()
      end
    end
  end

  defp all(solutions) do
    case Tree.next(solutions) do
      :empty -> []
      {:solution, bindings, rest} -> [bindings | all(rest)]
    end
  end
end
