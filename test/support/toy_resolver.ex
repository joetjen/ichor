defmodule ToyResolver do
  @moduledoc """
  A worked example for `Ichor.Toolkit.Scope`: variable resolution over a
  tiny toy AST (`{:var, name}` / `{:let, name, value, body}` /
  `{:lambda, params, body}` / `{:apply, fn_expr, args}`) -- the classic
  "does every variable reference resolve to something in scope" semantic
  check almost any real language's front-end needs, proving nested
  scoping, shadowing, and undefined-reference detection all work
  correctly, not just in isolated unit tests of `Scope` itself.
  """

  alias Ichor.Toolkit.Scope

  @spec resolve(term(), Scope.t()) :: :ok | {:error, String.t()}
  def resolve(expr, scope \\ Scope.new())

  def resolve({:var, name}, scope) do
    case Scope.lookup(scope, name) do
      {:ok, _bound} -> :ok
      :error -> {:error, "undefined variable #{inspect(name)}"}
    end
  end

  def resolve({:let, name, value_expr, body_expr}, scope) do
    with :ok <- resolve(value_expr, scope) do
      resolve(body_expr, Scope.define(scope, name, :bound))
    end
  end

  def resolve({:lambda, params, body}, scope) do
    inner = Enum.reduce(params, Scope.push(scope), &Scope.define(&2, &1, :bound))
    resolve(body, inner)
  end

  def resolve({:apply, fn_expr, args}, scope) do
    with :ok <- resolve(fn_expr, scope) do
      Enum.reduce_while(args, :ok, fn arg, :ok ->
        case resolve(arg, scope) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  def resolve(_literal, _scope), do: :ok
end
