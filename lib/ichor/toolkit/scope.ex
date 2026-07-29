defmodule Ichor.Toolkit.Scope do
  @moduledoc """
  A generic nested lexical scope / symbol table: a stack of name->value
  bindings, innermost scope first, supporting the "define here, look up
  through enclosing scopes" shape almost every real language's semantic
  analysis needs (variable resolution, nested function/block scoping,
  ...). No existing internal precedent to extract this from (unlike
  `Ichor.Toolkit.Fixpoint`/`Graph`) -- a from-scratch design, but a
  standard, well-understood one.

  Deliberately minimal: `define/3` never itself rejects a duplicate key
  in the same scope. Whether redefining a name within one scope is
  allowed is a real per-language policy choice (some languages reject
  it, some don't) -- left to the caller, via `lookup_local/2`, rather
  than baked in here. Nothing is grammar-specific; `key` can be any term
  with a working `==/2`, not just an atom.
  """

  @opaque t :: [%{term() => term()}]

  @doc "A fresh scope with just the outermost (global) level."
  @spec new() :: t()
  def new, do: [%{}]

  @doc "Enters a new, empty nested scope."
  @spec push(t()) :: t()
  def push(scope), do: [%{} | scope]

  @doc """
  Exits the current (innermost) scope, discarding its own bindings.
  Raises (`FunctionClauseError`) if there's no nested scope left to pop
  -- the outermost level, from `new/0`, is never popped, the same way
  popping an empty stack is a caller bug, not a recoverable condition.
  """
  @spec pop(t()) :: t()
  def pop([_innermost, _ | _] = scope), do: tl(scope)

  @doc "Binds `key` to `value` in the current (innermost) scope, shadowing any same-named binding in an enclosing one."
  @spec define(t(), term(), term()) :: t()
  def define([current | rest], key, value), do: [Map.put(current, key, value) | rest]

  @doc "Looks up `key`, searching from the innermost scope outward. `:error` if it's not bound anywhere."
  @spec lookup(t(), term()) :: {:ok, term()} | :error
  def lookup(scope, key) do
    Enum.find_value(scope, :error, fn level ->
      case Map.fetch(level, key) do
        {:ok, _value} = found -> found
        :error -> nil
      end
    end)
  end

  @doc "Looks up `key` in the current (innermost) scope only, not any enclosing one -- what a caller wanting to reject same-scope redefinition checks before calling `define/3`."
  @spec lookup_local(t(), term()) :: {:ok, term()} | :error
  def lookup_local([current | _], key), do: Map.fetch(current, key)
end
