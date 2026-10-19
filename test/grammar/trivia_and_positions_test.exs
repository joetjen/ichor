defmodule Grammar.TriviaAndPositionsTest do
  @moduledoc """
  Trivia around the input is skipped, and every parse error says
  where, by every engine and both backends alike -- the rule
  `Grammar.Source.trimmed/2` and `position/3` exist for.
  """

  use ExUnit.Case, async: true

  @grammars %{
    peg: ~S"""
    @grammar "sum"
    @root expr
    NUMBER := /\d+/
    expr := NUMBER (op:"+" NUMBER)*
    """,
    lr: ~S"""
    @grammar "sum"
    @root expr
    @engine lr
    NUMBER := /\d+/
    PLUS   := "+"
    expr := expr PLUS NUMBER | NUMBER
    """,
    glr: ~S"""
    @grammar "sum"
    @root expr
    @engine glr
    NUMBER := /\d+/
    PLUS   := "+"
    expr := expr PLUS NUMBER | NUMBER
    """
  }

  # `input` through `engine`'s grammar, by `backend`.
  defp run(engine, backend, input) do
    {:ok, grammar} = Aether.Parser.parse(@grammars[engine], nil)

    case backend do
      :interpreted ->
        {:ok, analysed} = Grammar.Analysis.run(grammar)
        module = %{peg: Grammar.VM, lr: Grammar.LR, glr: Grammar.GLR}[engine]
        module.run(analysed, input, Support.NoActions)

      :compiled ->
        name = Module.concat(__MODULE__, "P#{System.unique_integer([:positive])}")
        Module.create(name, Ichor.generate_from_grammar(grammar, Support.NoActions), __ENV__)
        name.run(input)
    end
  end

  # The value without the spans of its nodes: the same value, wherever
  # in the input it was.
  defp unplaced(%Ichor.Node{} = node),
    do: %{node | span: nil, captures: Map.new(node.captures, fn {k, v} -> {k, unplaced(v)} end)}

  defp unplaced(values) when is_list(values), do: Enum.map(values, &unplaced/1)

  defp unplaced(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> unplaced() |> List.to_tuple()

  defp unplaced(value), do: value

  defp place({:error, [error | _]}), do: place({:error, error})
  defp place({:error, error}), do: {error.stage, error.line, error.column}

  for engine <- [:peg, :lr, :glr], backend <- [:interpreted, :compiled] do
    describe "#{engine}, #{backend}" do
      test "skips space before the input" do
        assert {:ok, _} = run(unquote(engine), unquote(backend), "  1+2")
      end

      test "skips space after the input" do
        assert {:ok, _} = run(unquote(engine), unquote(backend), "1+2 \n")
      end

      test "parses the same with space around it as without" do
        assert unplaced(run(unquote(engine), unquote(backend), "\n 1+2 ")) ==
                 unplaced(run(unquote(engine), unquote(backend), "1+2"))
      end

      test "places no input at the first line and column" do
        assert place(run(unquote(engine), unquote(backend), "")) == {:parser, 1, 1}
      end

      test "places only space at the end of the input" do
        assert place(run(unquote(engine), unquote(backend), " \n  ")) == {:parser, 2, 3}
      end

      test "places a root that does not match where it was tried" do
        assert place(run(unquote(engine), unquote(backend), "  +1")) == {:parser, 1, 3}
      end

      # An ordered choice backtracks out of `(op:"+" NUMBER)*` and
      # reports the `+` left over; a shift-reduce parser has shifted it,
      # and runs into the end of the input.
      test "places input that ends too soon where the engine stopped" do
        expected = if unquote(engine) == :peg, do: {:parser, 1, 2}, else: {:parser, 1, 4}
        assert place(run(unquote(engine), unquote(backend), "1+ ")) == expected
      end
    end
  end
end
