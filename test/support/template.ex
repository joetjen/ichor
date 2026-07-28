defmodule Template do
  @moduledoc """
  A worked example for `Ichor.Toolkit.TermWalk`, deliberately unrelated
  to grammars, compilers, or logic/type systems: a tiny template AST
  (`{:lit, text}` / `{:var, name}` / `{:concat, [terms]}`) implementing
  `Ichor.Backtrack.Term`, proving `fold/4` ("which variables does this
  template reference") and `rewrite/3` ("substitute every variable with
  its bound value") both work over a domain with no logic-programming or
  type-inference concept in it at all.
  """

  @behaviour Ichor.Backtrack.Term

  @impl true
  def variable?({:var, _name}), do: true
  def variable?(_), do: false

  @impl true
  def var_id({:var, name}), do: name

  @impl true
  def compound?({:concat, _terms}), do: true
  def compound?(_), do: false

  @impl true
  def deconstruct({:concat, terms}), do: {:concat, terms}

  @impl true
  def reconstruct(:concat, terms), do: {:concat, terms}

  alias Ichor.Toolkit.TermWalk

  @doc "Every variable name `template` references, anywhere inside it."
  @spec variables(term()) :: MapSet.t(atom())
  def variables(template) do
    TermWalk.fold(__MODULE__, template, MapSet.new(), fn
      {:var, name}, acc -> MapSet.put(acc, name)
      _other, acc -> acc
    end)
  end

  @doc "Substitutes every `{:var, name}` in `template` with `bindings[name]`, then flattens to a string."
  @spec render(term(), %{atom() => String.t()}) :: String.t()
  def render(template, bindings) do
    term_module = __MODULE__

    substituted =
      TermWalk.rewrite(term_module, template, fn
        {:var, name} -> {:lit, Map.fetch!(bindings, name)}
        other -> other
      end)

    to_string_tree(substituted)
  end

  defp to_string_tree({:lit, text}), do: text
  defp to_string_tree({:concat, terms}), do: Enum.map_join(terms, "", &to_string_tree/1)
end
