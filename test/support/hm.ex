defmodule HM.Types do
  @moduledoc """
  Type representation for the `HM.Infer` worked example: `{:tvar, ref}`
  for a type variable, `{:tcon, name, args}` for a type constructor
  (`{:tcon, :int, []}`, `{:tcon, :->, [arg_type, result_type]}`).
  Implements `reconstruct/2` (unlike `Prolog.Terms`, which never needs
  it) since `Ichor.Toolkit.TypeScheme` has to rebuild types when
  generalizing/instantiating.
  """

  @behaviour Ichor.Backtrack.Term

  @impl true
  def variable?({:tvar, _id}), do: true
  def variable?(_), do: false

  @impl true
  def var_id({:tvar, id}), do: id

  @impl true
  def compound?({:tcon, _name, _args}), do: true
  def compound?(_), do: false

  @impl true
  def deconstruct({:tcon, name, args}), do: {name, args}

  @impl true
  def reconstruct(name, args), do: {:tcon, name, args}

  def fresh, do: {:tvar, make_ref()}
  def fn_type(arg, result), do: {:tcon, :->, [arg, result]}
  def int, do: {:tcon, :int, []}
  def string, do: {:tcon, :string, []}
end

defmodule HM.Infer do
  @moduledoc """
  A small Hindley-Milner type checker over a toy expression language
  (`{:int, n}` / `{:string, s}` / `{:var, name}` / `{:lambda, param,
  body}` / `{:apply, fn_expr, arg_expr}` / `{:let, name, value, body}` /
  `{:pair, e1, e2}` -- the last purely so one test expression can use a
  polymorphic binding at two different types at once, without needing a
  richer language) -- the worked example for `Ichor.Toolkit.TypeScheme`
  and `Ichor.Backtrack.Bindings.unify_occurs_check/4`.

  `mono_vars` (threaded through every call, growing only at `:lambda`)
  is the standard Hindley-Milner technique for tracking which type
  variables are still "free in the environment" (a lambda parameter's
  own type variable, specifically) and therefore must *not* be
  generalized by an enclosing `let` -- cheaper than re-scanning
  `Ichor.Toolkit.Scope`'s whole contents on every `let`.
  """

  alias Ichor.Backtrack.Bindings
  alias Ichor.Toolkit.{Scope, TypeScheme}
  alias HM.Types

  @spec infer(term(), Scope.t(), Bindings.t(), MapSet.t()) ::
          {:ok, term(), Bindings.t()} | {:error, String.t()}
  def infer(expr, scope, bindings, mono_vars \\ MapSet.new())

  def infer({:int, _n}, _scope, bindings, _mono_vars), do: {:ok, Types.int(), bindings}
  def infer({:string, _s}, _scope, bindings, _mono_vars), do: {:ok, Types.string(), bindings}

  def infer({:var, name}, scope, bindings, _mono_vars) do
    case Scope.lookup(scope, name) do
      {:ok, scheme} -> {:ok, TypeScheme.instantiate(Types, scheme, &Types.fresh/0), bindings}
      :error -> {:error, "undefined variable #{inspect(name)}"}
    end
  end

  def infer({:lambda, param, body}, scope, bindings, mono_vars) do
    param_type = Types.fresh()
    scope2 = scope |> Scope.push() |> Scope.define(param, {MapSet.new(), param_type})
    mono_vars2 = MapSet.put(mono_vars, Types.var_id(param_type))

    with {:ok, body_type, bindings2} <- infer(body, scope2, bindings, mono_vars2) do
      {:ok, Types.fn_type(param_type, body_type), bindings2}
    end
  end

  def infer({:apply, fn_expr, arg_expr}, scope, bindings, mono_vars) do
    with {:ok, fn_type, bindings1} <- infer(fn_expr, scope, bindings, mono_vars),
         {:ok, arg_type, bindings2} <- infer(arg_expr, scope, bindings1, mono_vars) do
      result_type = Types.fresh()

      case Bindings.unify_occurs_check(
             Types,
             bindings2,
             fn_type,
             Types.fn_type(arg_type, result_type)
           ) do
        {:ok, bindings3} -> {:ok, result_type, bindings3}
        :fail -> {:error, "cannot apply #{inspect(fn_type)} to #{inspect(arg_type)}"}
      end
    end
  end

  def infer({:let, name, value_expr, body_expr}, scope, bindings, mono_vars) do
    with {:ok, value_type, bindings1} <- infer(value_expr, scope, bindings, mono_vars) do
      scheme = TypeScheme.generalize(Types, bindings1, mono_vars, value_type)
      scope2 = scope |> Scope.push() |> Scope.define(name, scheme)
      infer(body_expr, scope2, bindings1, mono_vars)
    end
  end

  # A genuine {:tcon, :pair, [t1, t2]} compound type, not a bare Elixir
  # tuple -- the latter would escape HM.Types' own representation
  # entirely, meaning TypeScheme.resolve_deep/3 (which only knows how to
  # recurse into a proper Term-shaped compound) wouldn't be able to
  # resolve t1/t2 inside it at all.
  def infer({:pair, e1, e2}, scope, bindings, mono_vars) do
    with {:ok, t1, bindings1} <- infer(e1, scope, bindings, mono_vars),
         {:ok, t2, bindings2} <- infer(e2, scope, bindings1, mono_vars) do
      {:ok, {:tcon, :pair, [t1, t2]}, bindings2}
    end
  end
end
