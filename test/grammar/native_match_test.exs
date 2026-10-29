defmodule Grammar.NativeMatchTest do
  @moduledoc """
  Every generated parser offers `match/2`: the match `parse/2` and
  `run/2` share, with where each capture matched and the locator that
  places it, for a caller that wants spans and no actions -- under
  every engine, with actions or without. As the Praxis port's
  `ichor.grammar.match-test`.
  """

  use ExUnit.Case, async: true

  defp compiled(engine, actions) do
    source =
      "@grammar \"t\"\n@root all\n@engine #{engine}\n" <>
        "WORD := [a-z]+\nall := pair:(key:WORD \"=\" value:WORD)\n"

    {:ok, grammar} = Aether.Parser.parse(source, nil)
    name = Module.concat(__MODULE__, "P#{System.unique_integer([:positive])}")
    Module.create(name, Ichor.generate_from_grammar(grammar, actions), __ENV__)
    name
  end

  for engine <- [:peg, :lr, :glr], actions <- [nil, Support.NoActions] do
    test "#{engine}, #{if actions, do: "with", else: "without"} actions: match answers what parse does, with the locator" do
      module = compiled(unquote(engine), unquote(actions))

      assert {:ok, pos, raw_captures, locator} = module.match("a = b")
      assert {:ok, ^pos, plain} = module.parse("a = b")
      assert Ichor.Capture.plain(raw_captures) == plain
      assert locator != nil
      assert module.match("a = b", nil) == module.match("a = b")
      assert module.match("a =") == module.parse("a =")
    end
  end
end
