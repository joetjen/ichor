defmodule Ichor.Toolkit.TypeScheme do
  @moduledoc """
  Hindley-Milner-style let-polymorphism: `generalize/4` and
  `instantiate/3`, built on `Ichor.Backtrack.Bindings.unify_occurs_check/4`
  (plain `unify/4` deliberately has no occurs-check, matching ISO
  Prolog's own default -- a type checker needs one, or unifying a type
  variable with a type containing itself would silently build an
  infinite type instead of failing).

  A "scheme" is `{quantified :: MapSet.t(var_id), type}` -- `∀ quantified. type`
  in the usual notation. `generalize/4` computes one from a type and the
  set of type variables still free in the surrounding environment
  (never generalized away, since they belong to a binding whose own
  type isn't finished yet -- typically every currently-in-scope lambda
  parameter's own type variable); `instantiate/3` produces a fresh copy
  of a scheme's type, replacing every quantified variable with a newly
  minted one -- what makes `let id = fn x -> x in (id 1, id "s")`
  type-check, with two different instantiations of the same
  polymorphic `id`.

  Both need to *rebuild* a term (substituting quantified variables), so
  `term_module` must implement `Ichor.Backtrack.Term`'s optional
  `reconstruct/2` callback -- the one piece of this module that needs
  construction, not just inspection, of a term.
  """

  alias Ichor.Backtrack.Bindings
  alias Ichor.Toolkit.TermWalk

  @type scheme :: {MapSet.t(term()), term()}

  @doc "Every type variable free in `term`, after resolving through `bindings`."
  @spec free_vars(module(), Bindings.t(), term()) :: MapSet.t(term())
  def free_vars(term_module, bindings, term) do
    resolved = resolve_deep(term_module, bindings, term)

    TermWalk.fold(term_module, resolved, MapSet.new(), fn t, acc ->
      if term_module.variable?(t), do: MapSet.put(acc, term_module.var_id(t)), else: acc
    end)
  end

  @doc """
  Generalizes `type` into a scheme: deep-resolves `type` through
  `bindings` (so the scheme is self-contained -- reusable later, even
  after `bindings` itself has moved on), then quantifies every free
  variable *not* also present in `env_free_vars`.
  """
  @spec generalize(module(), Bindings.t(), MapSet.t(term()), term()) :: scheme()
  def generalize(term_module, bindings, env_free_vars, type) do
    resolved = resolve_deep(term_module, bindings, type)
    quantified = MapSet.difference(free_vars(term_module, bindings, resolved), env_free_vars)
    {quantified, resolved}
  end

  @doc """
  Fully resolves `term` through `bindings`, recursively -- unlike
  `Ichor.Backtrack.Bindings.resolve/3` (shallow, stops at the first
  non-variable), this also resolves every bound variable nested inside
  a compound term. Useful on its own for displaying/comparing a type
  once inference is done, not just as `generalize/4`'s own first step.
  """
  @spec resolve_deep(module(), Bindings.t(), term()) :: term()
  def resolve_deep(term_module, bindings, term) do
    TermWalk.rewrite(term_module, term, &Bindings.resolve(term_module, bindings, &1))
  end

  @doc """
  Produces a fresh copy of `scheme`'s type, replacing every quantified
  variable with a newly minted one (`fresh_var_fn.()`), consistently
  for repeated occurrences of the same variable -- a monomorphic scheme
  (`quantified` empty, e.g. a lambda parameter's own binding) is
  returned unchanged.
  """
  @spec instantiate(module(), scheme(), (-> term())) :: term()
  def instantiate(term_module, {quantified, type}, fresh_var_fn) do
    substitution = Map.new(quantified, fn var_id -> {var_id, fresh_var_fn.()} end)
    substitute(term_module, substitution, type)
  end

  defp substitute(term_module, substitution, term) do
    TermWalk.rewrite(term_module, term, fn t ->
      if term_module.variable?(t),
        do: Map.get(substitution, term_module.var_id(t), t),
        else: t
    end)
  end
end
