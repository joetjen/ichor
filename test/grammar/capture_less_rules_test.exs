defmodule Grammar.CaptureLessRulesTest do
  @moduledoc """
  A rule that captures nothing is the text it matched -- by every
  engine and both backends alike.

  A rule built only from literals used to come out as an empty node, so
  what it matched was lost to whatever the parse was fed to: an
  interpreter fed `num := "1" | "2"` could not tell `1` from `2`. In an
  ABNF, BNF, EBNF or PEG grammar, which have no capture syntax, that was
  every terminal. Now such a rule captures its own text under `:text`:
  the default tree makes that the string, and an actions module finds
  it in `%{text: ...}`.

  **Decided by the grammar, not by the input**: a rule is capture-less
  when nothing in its body is captured, so it is a string for every
  input and never a node for some and a string for others.
  """

  use ExUnit.Case, async: true

  defmodule Spoken do
    @moduledoc "Says what each rule was given."
    @behaviour Ichor.Actions
    @impl Ichor.Actions
    def handle_rule(:num, captures, ctx) do
      with {:ok, values, ctx} <- Ichor.Actions.eval_all(captures, ctx) do
        {:ok, {:num, values}, ctx}
      end
    end
  end

  @grammars %{
    peg: ~S"""
    @grammar "sum"
    @root sum
    @noskip
    sum := num ("+" num)?
    num := "1" | "2" | "12"
    """,
    lr: ~S"""
    @grammar "sum"
    @root sum
    @engine lr
    @noskip
    sum := num "+" num | num
    num := "1" | "2"
    """,
    glr: ~S"""
    @grammar "sum"
    @root sum
    @engine glr
    @noskip
    sum := num "+" num | num
    num := "1" | "2"
    """
  }

  defp run(engine, backend, source, input, actions \\ Support.NoActions) do
    {:ok, grammar} = Aether.Parser.parse(source, nil)

    case backend do
      :interpreted ->
        {:ok, analysed} = Grammar.Analysis.run(grammar)
        module = %{peg: Grammar.VM, lr: Grammar.LR, glr: Grammar.GLR}[engine]
        module.run(analysed, input, actions)

      :compiled ->
        name = Module.concat(__MODULE__, "P#{System.unique_integer([:positive])}")
        Module.create(name, Ichor.generate_from_grammar(grammar, actions), __ENV__)
        name.run(input)
    end
  end

  for engine <- [:peg, :lr, :glr], backend <- [:interpreted, :compiled] do
    describe "#{engine}, #{backend}" do
      test "a rule of literals alone is the text it matched" do
        assert {:ok, %Ichor.Node{rule: :sum, captures: %{num: ["1", "2"]}}} =
                 run(unquote(engine), unquote(backend), @grammars[unquote(engine)], "1+2")
      end

      test "an actions module finds the text under :text" do
        assert {:ok, %Ichor.Node{captures: %{num: [{:num, %{text: "1"}}, {:num, %{text: "2"}}]}}} =
                 run(unquote(engine), unquote(backend), @grammars[unquote(engine)], "1+2", Spoken)
      end
    end
  end

  test "a capture-less root is the whole input it matched" do
    grammar = "@grammar \"r\"\n@root r\n@noskip\nr := \"a\" \"b\"\n"

    for backend <- [:interpreted, :compiled] do
      assert run(:peg, backend, grammar, "ab") == {:ok, "ab"}
    end
  end

  test "the text runs from the rule's first token to its last, trivia between them included" do
    grammar = "@grammar \"r\"\n@root r\nr := pair\npair := \"a\" \"b\"\n"

    for backend <- [:interpreted, :compiled] do
      assert run(:peg, backend, grammar, "a  b") == {:ok, "a  b"}
    end
  end

  # `(x:"q")?` captures `x` only when there is a `q`; the rule is not
  # capture-less, so where nothing matched it stays an empty node rather
  # than becoming a string for this one input.
  test "a rule with a capture in it is never its text, even where nothing was captured" do
    grammar = "@grammar \"r\"\n@root r\n@noskip\nr := s s\ns := (x:\"q\")?\n"

    for backend <- [:interpreted, :compiled] do
      assert {:ok, %Ichor.Node{captures: %{s: ["q", %Ichor.Node{rule: :s, captures: %{}}]}}} =
               run(:peg, backend, grammar, "q")
    end
  end
end
