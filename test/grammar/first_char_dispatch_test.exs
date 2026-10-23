defmodule Grammar.FirstCharDispatchTest do
  @moduledoc """
  A generated tokenizer tries at each position only the tokens that can
  begin with the next character (`Grammar.FirstChars`), and still finds
  exactly the tokens the interpreter finds: the same winner of maximal
  munch, the same declaration-order tie-break, the same error where
  nothing matches.
  """

  use ExUnit.Case, async: true

  # Overlapping starts (`IDENT` and the keyword literal), a token that
  # may begin with a sign or a digit, one that begins with anything
  # (`.`-led `OTHER`), and a token whose leading part can match nothing.
  @grammar ~S"""
  @grammar "starts"
  @root items
  @noskip
  WS     := [ \n]+
  NUM    := "-"? [0-9]+ ("." [0-9]+)?
  IDENT  := [a-zA-Zä_] [a-zA-Z0-9_]*
  PAD    := "~"* "#" [a-z]*
  OTHER  := !(WS | NUM | IDENT | PAD | "let") .
  items  := ("let" | WS | NUM | IDENT | PAD | OTHER)*
  """

  defp grammar do
    {:ok, grammar} = Aether.Parser.parse(@grammar, nil)
    grammar
  end

  defp compiled do
    name = Module.concat(__MODULE__, "Starts")

    unless Code.ensure_loaded?(name) do
      Module.create(name, Ichor.generate_from_grammar(grammar(), Support.NoActions), __ENV__)
    end

    name
  end

  defp interpreted(input) do
    {:ok, analysed} = Grammar.Analysis.run(grammar())
    Grammar.VM.tokenize(analysed, input, nil)
  end

  defp names({:ok, tokens}), do: Enum.map(tokens, &{&1.name, &1.text})
  defp names(other), do: other

  for input <- [
        "let letter -1.5 ä_x9",
        "~~#ab #c -7 12.25",
        "@ % let$ 3 é",
        "",
        "let\nlet"
      ] do
    test "the generated tokenizer finds what the interpreter finds in #{inspect(input)}" do
      assert names(compiled().tokenize(unquote(input))) == names(interpreted(unquote(input)))
    end
  end

  test "the generated tokenizer asks each token's start set before trying it" do
    source = Macro.to_string(Ichor.generate_from_grammar(grammar(), Support.NoActions))

    [lex_candidates] = Regex.run(~r/defp lex_candidates\(.*?\nend\n/s, source)

    assert lex_candidates =~ "Tokenizer.in_class?("
  end
end
