defmodule Ichor.Toolkit.TermWalk do
  @moduledoc """
  Generic recursion over any `Ichor.Backtrack.Term` implementation --
  extracted from a pattern independently duplicated inside
  `Ichor.Toolkit.TypeScheme` itself: `resolve_deep/3` and the private
  `substitute/3` shared the identical "apply a transform, then (if the
  result is compound) deconstruct, recurse into every argument with the
  same transform, and reconstruct" recursive skeleton, differing only in
  what the transform itself does at each step (chase a variable's
  binding one level, or substitute a specific variable for a fresh one);
  `free_vars/3` is the same recursive shape again, but folding into an
  accumulator instead of rebuilding a term.

  Neither function here knows anything about bindings, substitutions, or
  types -- only what `variable?/1`, `compound?/1`, `deconstruct/1`, and
  (for `rewrite/3`) `reconstruct/2` say about a given `term_module`, the
  same boundary `Ichor.Backtrack.Bindings.unify/4` already draws.
  """

  @doc """
  Folds over `term` and every subterm reachable through `compound?/1`/
  `deconstruct/1`, visiting a node before its children (order doesn't
  matter for a commutative `combine`, e.g. collecting a set of variable
  ids -- `Ichor.Toolkit.TypeScheme.free_vars/3`'s own use).
  """
  @spec fold(module(), term(), acc, (term(), acc -> acc)) :: acc when acc: term()
  def fold(term_module, term, acc, combine) do
    acc = combine.(term, acc)

    if term_module.compound?(term) do
      {_functor, args} = term_module.deconstruct(term)
      Enum.reduce(args, acc, &fold(term_module, &1, &2, combine))
    else
      acc
    end
  end

  @doc """
  Applies `transform` to `term`, then -- if the *result* is compound --
  deconstructs it and recurses into every argument with the same
  `transform`, reconstructing afterward. `transform` is applied exactly
  once per node, on the way down, never re-applied to a freshly
  reconstructed compound -- correct for a transform that only ever acts
  on non-compound nodes (resolving or substituting a variable; a
  compound term is rebuilt from its already-transformed arguments, never
  itself examined), which is the only shape `resolve_deep/3`/`substitute/3`
  ever needed. Not a general bottom-up rewrite pass (e.g. constant
  folding, which needs to re-examine a parent after its children
  change) -- `transform` never sees a node built by this same call.
  """
  @spec rewrite(module(), term(), (term() -> term())) :: term()
  def rewrite(term_module, term, transform) do
    term = transform.(term)

    if term_module.compound?(term) do
      {functor, args} = term_module.deconstruct(term)
      term_module.reconstruct(functor, Enum.map(args, &rewrite(term_module, &1, transform)))
    else
      term
    end
  end
end
