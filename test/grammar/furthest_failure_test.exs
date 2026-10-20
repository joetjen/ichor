defmodule Grammar.FurthestFailureTest do
  @moduledoc """
  A PEG parse that fails says where it went wrong: at the furthest token
  any alternative reached, with what would have been accepted there --
  not at the first token, where the root was tried. By both backends,
  and in a sequence of top-level matches.
  """

  use ExUnit.Case, async: true

  @grammar ~S"""
  @grammar "entries"
  @root doc
  @skip WS
  WS   := [ \n]+
  INT  := [0-9]+
  NAME := [a-z]+
  doc   := "{" entry* "}"
  entry := NAME ":" value
  value := INT | list
  list  := "[" value* "]"
  """

  defp grammar(source) do
    {:ok, grammar} = Aether.Parser.parse(source, nil)
    grammar
  end

  defp run(:interpreted, source, input) do
    {:ok, analysed} = Grammar.Analysis.run(grammar(source))
    Grammar.VM.run(analysed, input, Support.NoActions)
  end

  defp run(:compiled, source, input) do
    name = Module.concat(__MODULE__, "P#{System.unique_integer([:positive])}")
    Module.create(name, Ichor.generate_from_grammar(grammar(source), Support.NoActions), __ENV__)
    name.run(input)
  end

  defp failure({:error, error}), do: error

  for backend <- [:interpreted, :compiled] do
    describe "#{backend}" do
      test "a failed parse is placed at the furthest token reached" do
        error = failure(run(unquote(backend), @grammar, "{\n  a: [\n}\n"))
        assert {error.stage, error.line, error.column} == {:parser, 3, 1}
      end

      test "and says what was found there and what would have been accepted" do
        error = failure(run(unquote(backend), @grammar, "{\n  a: [\n}\n"))
        assert error.message == ~s(unexpected "}" -- expected one of: "[", "]", INT)
        assert {error.found, error.expected} == {"}", [~s("["), ~s("]"), "INT"]}
        assert error.context_lines == "3 | }\n  | ^"
      end

      test "running out of input is unexpected end of input, at the end" do
        error = failure(run(unquote(backend), @grammar, "{ a: [ 1"))
        assert {error.line, error.column} == {1, 9}
        assert error.message == ~s(unexpected end of input -- expected one of: "[", "]", INT)
        assert error.found == :eof
      end

      test "one thing expected is named alone" do
        error = failure(run(unquote(backend), @grammar, "{ a 1 }"))
        assert {error.line, error.column} == {1, 5}
        assert error.message == ~s(unexpected "1" -- expected ":")
      end

      test "input left over after a complete match is still that" do
        error = failure(run(unquote(backend), @grammar, "{ a: 1 } x"))
        assert {error.line, error.column} == {1, 10}
        assert error.message == ~s(unexpected "x" -- did not expect more input here)
      end

      # Inside `!X` or `&X` a failed match is no expectation: `!STR` not
      # matching is what lets the parse go on.
      test "what a lookahead failed to match is not something expected" do
        source = ~S"""
        @grammar "look"
        @root doc
        @skip WS
        WS   := [ ]+
        INT  := [0-9]+
        NAME := [a-z]+
        STR  := "'" [a-z]* "'"
        doc  := NAME !STR INT
        """

        error = failure(run(unquote(backend), source, "a b"))
        assert {error.line, error.column} == {1, 3}
        assert error.expected == ["INT"]
      end

      test "a match that succeeds leaves nothing behind for the next parse" do
        assert {:ok, _} = run(unquote(backend), @grammar, "{ a: [1 2] }")
        error = failure(run(unquote(backend), @grammar, "{ a 1 }"))
        assert error.expected == [~s(":")]
      end
    end
  end

  describe "a sequence of top-level matches" do
    @entries ~S"""
    @grammar "entries"
    @root entry
    @skip WS
    WS   := [ \n]+
    INT  := [0-9]+
    NAME := [a-z]+
    entry := NAME ":" INT
    """

    test "a later match that fails is placed where it went wrong, interpreted" do
      {:ok, analysed} = Grammar.Analysis.run(grammar(@entries))
      {:error, error} = Grammar.VM.run_sequence(analysed, "a: 1\nb: c", Support.NoActions, nil)

      assert {error.line, error.column, error.message} ==
               {2, 4, ~s(unexpected "c" -- expected INT)}
    end

    test "and compiled" do
      name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")

      Module.create(
        name,
        Ichor.generate_from_grammar(grammar(@entries), Support.NoActions),
        __ENV__
      )

      {:error, error} = name.run_sequence("a: 1\nb: c", nil)

      assert {error.line, error.column, error.message} ==
               {2, 4, ~s(unexpected "c" -- expected INT)}
    end
  end
end
