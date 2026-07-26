defmodule Lisp.Primitives do
  @moduledoc """
  Layer 1 of the three-layer bootstrap: Elixir-native bindings seeded
  into an empty context before any Lisp
  code -- including `stdlib.lisp` itself -- runs. Nothing here is written
  in Lisp; it has to exist before any Lisp code can run at all.
  """

  alias Lisp.{Keyword, Symbol, Vector}

  @spec seed(Lisp.Actions.context()) :: Lisp.Actions.context()
  def seed(ctx) do
    %{ctx | env: Map.merge(ctx.env, bindings())}
  end

  defp bindings do
    %{
      "true" => true,
      "false" => false,
      "nil" => nil,
      "+" => fn args -> Enum.sum(args) end,
      "-" => fn [first | rest] -> Enum.reduce(rest, first, &(&2 - &1)) end,
      "*" => fn args -> Enum.reduce(args, 1, &(&2 * &1)) end,
      "/" => fn [first | rest] -> Enum.reduce(rest, first, &(&2 / &1)) end,
      "=" => fn args -> args |> Enum.uniq() |> length() == 1 end,
      "<" => fn [a, b] -> a < b end,
      ">" => fn [a, b] -> a > b end,
      "not" => fn [x] -> !truthy?(x) end,
      "list" => fn args -> args end,
      "cons" => fn [x, list] -> [x | list] end,
      "first" => fn [list] -> first_of(list) end,
      "second" => fn [list] -> first_of(rest_of(list)) end,
      "rest" => fn [list] -> rest_of(list) end,
      "car" => fn [list] -> first_of(list) end,
      "cdr" => fn [list] -> rest_of(list) end,
      "with-meta" => fn [target, meta] -> with_meta(target, meta) end,
      "meta" => fn [target] -> meta_of(target) end
    }
  end

  defp first_of([]), do: nil
  defp first_of([h | _]), do: h
  defp first_of(%Vector{items: items}), do: first_of(items)

  defp rest_of([]), do: []
  defp rest_of([_ | t]), do: t
  defp rest_of(%Vector{items: items}), do: rest_of(items)

  defp with_meta(%Symbol{} = s, meta), do: %{s | meta: meta}
  defp with_meta(other, _meta), do: other

  defp meta_of(%Symbol{meta: meta}), do: meta
  defp meta_of(%Keyword{}), do: nil
  defp meta_of(_other), do: nil

  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true
end
