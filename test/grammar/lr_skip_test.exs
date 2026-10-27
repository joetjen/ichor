defmodule Grammar.LRSkipTest do
  @moduledoc """
  Under `@engine lr` and `@engine glr`, the skip token is dropped from
  the stream before parsing rather than spliced into the rules. Spliced,
  `@skip` makes it optional between any two elements, and an optional
  element between two others leaves two of those side by side: a table
  with one token of lookahead cannot tell which one a space belongs to,
  so `"[" WORD* "]"` was refused as a conflict on the skip token. By
  both backends, and losslessly too.
  """

  use ExUnit.Case, async: true

  @grammar ~S"""
  @grammar "brackets"
  @root list
  @engine ENGINE
  WORD := [a-z]+
  list := "[" WORD* "]"
  """

  defp grammar(engine) do
    {:ok, grammar} = Aether.Parser.parse(String.replace(@grammar, "ENGINE", "#{engine}"), nil)
    grammar
  end

  defp interpreted(engine), do: %{lr: Grammar.LR, glr: Grammar.GLR}[engine]

  defp compiled(engine) do
    name = Module.concat(__MODULE__, "P#{engine}")

    unless Code.ensure_loaded?(name) do
      code = Ichor.generate_from_grammar(grammar(engine), Support.NoActions, lossless: true)
      Module.create(name, code, __ENV__)
    end

    name
  end

  defp run(engine, :interpreted, input) do
    {:ok, analysed} = Grammar.Analysis.run(grammar(engine))
    interpreted(engine).run(analysed, input, Support.NoActions)
  end

  defp run(engine, :compiled, input), do: compiled(engine).run(input)

  defp run_lossless(engine, :interpreted, input) do
    {:ok, analysed} = Grammar.Analysis.run(grammar(engine))
    interpreted(engine).run_lossless(analysed, input, Support.NoActions)
  end

  defp run_lossless(engine, :compiled, input), do: compiled(engine).run_lossless(input)

  test "an optional element between two others compiles under @engine lr" do
    {:ok, analysed} = Grammar.Analysis.run(grammar(:lr))
    assert {:ok, _} = Grammar.LR.compile(analysed)
  end

  for engine <- [:lr, :glr], backend <- [:interpreted, :compiled] do
    describe "#{engine}, #{backend}" do
      test "skip tokens may stand anywhere between the tokens" do
        for input <- ["[ab cd]", "[]", " [ ] ", "[  ab   cd  ]"] do
          assert {:ok, _} = run(unquote(engine), unquote(backend), input), input
        end
      end

      test "what the rules do not allow is still refused" do
        assert {:error, _} = run(unquote(engine), unquote(backend), "[ab")
        assert {:error, _} = run(unquote(engine), unquote(backend), "ab]")
      end

      test "the lossless tree still holds every byte of the input" do
        input = " [ ab  cd ] "
        assert {:ok, _value, tree} = run_lossless(unquote(engine), unquote(backend), input)
        assert Ichor.Syntax.text(tree) == input
      end
    end
  end

  for engine <- [:lr, :glr] do
    test "~ is refused under @engine #{engine}, which cannot keep the skip token out" do
      source = ~s"""
      @grammar "joined"
      @root pair
      @engine #{unquote(engine)}
      WORD := [a-z]+
      pair := WORD ~WORD
      """

      assert {:error, error} = Aether.Parser.parse(source, nil)
      assert error.message =~ "~"
      assert error.message =~ "@engine #{unquote(engine)}"
      # At the reference `~` stands in front of.
      assert {error.line, error.column} == {5, 15}
    end
  end

  # Under `@noskip` there is no skip token, and a rule named `nil` is
  # the atom `nil` too: 0.7.3 took the one for the other and refused it.
  for engine <- [:lr, :glr] do
    test "a rule named nil under @noskip is a rule like any other, under @engine #{engine}" do
      source = ~s"""
      @grammar "owned"
      @root r
      @engine #{unquote(engine)}
      @noskip
      A := "a"
      r := x:nil?
      nil := A
      """

      {:ok, grammar} = Aether.Parser.parse(source, nil)
      {:ok, analysed} = Grammar.Analysis.run(grammar)
      backend = %{lr: Grammar.LR, glr: Grammar.GLR}[unquote(engine)]
      assert {:ok, _} = backend.run(analysed, "a", Support.NoActions)
    end
  end

  test "a rule naming the skip token itself is refused, saying why" do
    source = ~S"""
    @grammar "spaced"
    @root pair
    @engine lr
    WORD := [a-z]+
    pair := WORD SPACE WORD
    """

    {:ok, grammar} = Aether.Parser.parse(source, nil)
    {:ok, analysed} = Grammar.Analysis.run(grammar)
    assert {:error, [error | _]} = Grammar.LR.compile(analysed)
    assert error.message =~ "SPACE"
    assert error.message =~ "skip"
  end
end
