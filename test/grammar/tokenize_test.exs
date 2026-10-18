defmodule Grammar.TokenizeTest do
  @moduledoc """
  `Grammar.VM.tokenize/3` -- a grammar's token stream for an input,
  interpreted -- answers what a generated module's own `tokenize/2`
  answers, for every engine.
  """

  use ExUnit.Case, async: true

  @grammars %{
    peg:
      "@grammar \"t\"\n@root r\nWORD := [a-z]+\n@keywords WORD { \"if\" -> KW_IF }\nr := (WORD | KW_IF)*\n",
    lr: "@grammar \"t\"\n@root r\n@engine lr\nN := [0-9]+\nr := r \"+\" N | N\n",
    glr: "@grammar \"t\"\n@root r\n@engine glr\nN := [0-9]+\nr := r \"+\" N | N\n"
  }

  defp both(engine, input) do
    {:ok, grammar} = Aether.Parser.parse(@grammars[engine], nil)
    {:ok, analysed} = Grammar.Analysis.run(grammar)
    name = Module.concat(__MODULE__, "T#{System.unique_integer([:positive])}")
    Module.create(name, Ichor.generate_from_grammar(grammar, Support.NoActions), __ENV__)
    {Grammar.VM.tokenize(analysed, input), name.tokenize(input, nil)}
  end

  for engine <- [:peg, :lr, :glr] do
    test "#{engine}: the interpreted token stream is the generated one" do
      input = if unquote(engine) == :peg, do: "if iffy if", else: "1 + 22"
      {interpreted, generated} = both(unquote(engine), input)
      assert {:ok, [_ | _]} = interpreted
      assert interpreted == generated
    end
  end

  test "keywords are reclassified, and trivia is in the stream" do
    {{:ok, tokens}, _} = both(:peg, "if iffy")

    assert Enum.map(tokens, &{&1.name, &1.text}) == [
             {:KW_IF, "if"},
             {:SPACE, " "},
             {:WORD, "iffy"}
           ]
  end

  test "a character no token matches is a lexer error where it is" do
    {interpreted, generated} = both(:peg, "if $")
    assert {:error, %Ichor.Error{stage: :lexer, line: 1, column: 4}} = interpreted
    assert interpreted == generated
  end
end
