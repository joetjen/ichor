defmodule Grammar.LRCaptureTextTest do
  @moduledoc """
  A capture over several tokens holds the input between its first and
  last token, skip tokens included, under every engine and backend.
  Since LR and GLR parse a stream without its skip tokens
  (`Grammar.Source.significant/2`), their captures lost the whitespace
  inside them: `all:(key:WORD "=" WORD)` on "a = b" came out as "a=b".
  PEG is the reference.
  """

  use ExUnit.Case, async: true

  @cases [
    {"all := whole\nwhole := all:(key:WORD \"=\" WORD)", "a = b", :all, "a = b"},
    {"all := pair:(key:WORD \"=\" value:WORD)", "a  =\n b", :pair, "a  =\n b"},
    {"all := \"[\" items:item* \"]\"\nitem := WORD", "[a b  c]", :items, "a b  c"},
    {"all := many:(WORD*) \";\"", " a a ;", :many, "a a"}
  ]

  defp grammar(body, engine) do
    source = "@grammar \"t\"\n@root all\n@engine #{engine}\nWORD := [a-z]+\n#{body}\n"
    {:ok, grammar} = Aether.Parser.parse(source, nil)
    grammar
  end

  defp run(body, engine, :interpreted, input) do
    {:ok, analysed} = Grammar.Analysis.run(grammar(body, engine))
    backend = %{peg: Grammar.VM, lr: Grammar.LR, glr: Grammar.GLR}[engine]
    backend.run(analysed, input, Support.NoActions)
  end

  defp run(body, engine, :compiled, input) do
    name = Module.concat(__MODULE__, "P#{System.unique_integer([:positive])}")

    Module.create(
      name,
      Ichor.generate_from_grammar(grammar(body, engine), Support.NoActions),
      __ENV__
    )

    name.run(input)
  end

  # The captured text under `key`, wherever the default tree puts it; a
  # root whose only capture it is answers the text itself.
  defp captured({:ok, text}, _key) when is_binary(text), do: text
  defp captured({:ok, value}, key), do: find(value, key)

  defp find(%{} = map, key) do
    case Map.fetch(map, key) do
      {:ok, text} when is_binary(text) -> text
      {:ok, [_ | _] = list} -> Enum.join(Enum.map(list, &text_of/1), " ")
      _ -> map |> Map.values() |> Enum.find_value(&find(&1, key))
    end
  end

  defp find(%{__struct__: _} = struct, key), do: find(Map.from_struct(struct), key)
  defp find(list, key) when is_list(list), do: Enum.find_value(list, &find(&1, key))
  defp find(_other, _key), do: nil

  defp text_of(text) when is_binary(text), do: text
  defp text_of(other), do: inspect(other)

  for {body, input, key, expected} <- @cases,
      engine <- [:peg, :lr, :glr],
      backend <- [:interpreted, :compiled] do
    test "#{engine}, #{backend}: #{key} on #{inspect(input)} is #{inspect(expected)}" do
      result = run(unquote(body), unquote(engine), unquote(backend), unquote(input))
      assert captured(result, unquote(key)) == unquote(expected)
    end
  end
end
