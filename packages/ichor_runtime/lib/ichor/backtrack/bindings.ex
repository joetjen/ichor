defmodule Ichor.Backtrack.Bindings do
  @moduledoc """
  A substitution: which logic variables are bound to which terms so
  far, opaque outside this module. `unify/4` is the whole unification
  algorithm -- standard, recursive, structural unification with no
  occurs-check (matches ISO Prolog's own default: `X = f(X)` succeeds,
  building a cyclic term, rather than failing or looping to detect the
  cycle -- occurs-check is opt-in in real Prolog too, via `unify_with_occurs_check/2`,
  never the default).

  Every function takes a `term_module` argument (an
  `Ichor.Backtrack.Term` implementation) explicitly, so this module
  never needs to know what a caller's own term representation looks
  like.
  """

  alias Ichor.Toolkit.Result

  @opaque t :: %{term() => term()}

  @doc "An empty substitution."
  @spec new() :: t()
  def new, do: %{}

  @doc "Extends `bindings`, binding `var_id` to `value`."
  @spec bind(t(), term(), term()) :: t()
  def bind(bindings, var_id, value), do: Map.put(bindings, var_id, value)

  @doc """
  Follows variable bindings until reaching either an unbound variable
  or a non-variable term -- shallow dereferencing only (never recurses
  into a compound term's own arguments), matching Prolog's own `deref`.
  """
  @spec resolve(module(), t(), term()) :: term()
  def resolve(term_module, bindings, term) do
    if term_module.variable?(term) do
      case Map.fetch(bindings, term_module.var_id(term)) do
        {:ok, bound} -> resolve(term_module, bindings, bound)
        :error -> term
      end
    else
      term
    end
  end

  @doc """
  Unifies `a` and `b` under `bindings`, extending them on success.
  Two distinct (by `var_id/1`) unbound variables unify by binding one
  to the other; an unbound variable and anything else unify by binding
  the variable; two compound terms unify when their functor and arity
  match and every argument pairwise unifies; anything else unifies with
  plain `==/2`.
  """
  @spec unify(module(), t(), term(), term()) :: {:ok, t()} | :fail
  def unify(term_module, bindings, a, b), do: do_unify_top(term_module, bindings, a, b, false)

  @doc """
  Like `unify/4`, but with an occurs-check: a variable is never allowed
  to bind to a compound term containing itself, which would otherwise
  silently build an infinite term (`X = f(X)`). `unify/4`'s own absence
  of this matches ISO Prolog's own default, not what a type checker
  needs -- `Ichor.Toolkit.TypeScheme` is built on this variant
  specifically because unifying two types this way must fail (not loop
  forever, not silently accept an infinite type) when one contains a
  variable already bound to (or literally equal to) the other.
  """
  @spec unify_occurs_check(module(), t(), term(), term()) :: {:ok, t()} | :fail
  def unify_occurs_check(term_module, bindings, a, b),
    do: do_unify_top(term_module, bindings, a, b, true)

  defp do_unify_top(term_module, bindings, a, b, occurs_check?) do
    a = resolve(term_module, bindings, a)
    b = resolve(term_module, bindings, b)
    do_unify(term_module, bindings, a, b, occurs_check?)
  end

  defp do_unify(term_module, bindings, a, b, occurs_check?) do
    a_var? = term_module.variable?(a)
    b_var? = term_module.variable?(b)

    cond do
      a_var? and b_var? and term_module.var_id(a) == term_module.var_id(b) ->
        {:ok, bindings}

      a_var? ->
        bind_checked(term_module, bindings, term_module.var_id(a), b, occurs_check?)

      b_var? ->
        bind_checked(term_module, bindings, term_module.var_id(b), a, occurs_check?)

      term_module.compound?(a) and term_module.compound?(b) ->
        unify_compound(term_module, bindings, a, b, occurs_check?)

      true ->
        if a == b, do: {:ok, bindings}, else: :fail
    end
  end

  defp bind_checked(term_module, bindings, var_id, term, true) do
    if occurs?(term_module, bindings, var_id, term) do
      :fail
    else
      {:ok, bind(bindings, var_id, term)}
    end
  end

  defp bind_checked(_term_module, bindings, var_id, term, false),
    do: {:ok, bind(bindings, var_id, term)}

  defp occurs?(term_module, bindings, var_id, term) do
    term = resolve(term_module, bindings, term)

    cond do
      term_module.variable?(term) ->
        term_module.var_id(term) == var_id

      term_module.compound?(term) ->
        {_functor, args} = term_module.deconstruct(term)
        Enum.any?(args, &occurs?(term_module, bindings, var_id, &1))

      true ->
        false
    end
  end

  defp unify_compound(term_module, bindings, a, b, occurs_check?) do
    {functor_a, args_a} = term_module.deconstruct(a)
    {functor_b, args_b} = term_module.deconstruct(b)

    if functor_a == functor_b and length(args_a) == length(args_b) do
      args_a
      |> Enum.zip(args_b)
      |> Result.reduce_ok(bindings, fn {x, y}, acc ->
        do_unify_top(term_module, acc, x, y, occurs_check?)
      end)
    else
      :fail
    end
  end
end
