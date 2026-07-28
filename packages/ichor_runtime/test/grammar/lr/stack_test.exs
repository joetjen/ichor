defmodule Grammar.LR.StackTest do
  use ExUnit.Case, async: true

  alias Grammar.LR.Stack
  alias Grammar.LRTable.Production
  alias Grammar.VM.Token

  test "push_token/5 lands a shifted token on top, tagged with its target state" do
    stack = Stack.push_token([], 3, %Token{name: :NUM, text: "1"}, 0, 1)
    assert [{3, 0, 1, %Token{name: :NUM}}] = stack
  end

  test "reduce/4 pops a production's own RHS, builds captures, exposes the state underneath" do
    # a := NUM PLUS NUM, both NUMs captured as :n (list-accumulated)
    production = %Production{
      id: 0,
      lhs: :a,
      rhs: [{:terminal, :NUM}, {:terminal, :PLUS}, {:terminal, :NUM}],
      captures: [{0, :n, :token}, {2, :n, :token}]
    }

    stream =
      {%Token{name: :NUM, text: "1"}, %Token{name: :PLUS, text: "+"},
       %Token{name: :NUM, text: "2"}}

    stack =
      [{0, 0, 0, nil}]
      |> Stack.push_token(1, elem(stream, 0), 0, 1)
      |> Stack.push_token(2, elem(stream, 1), 1, 2)
      |> Stack.push_token(3, elem(stream, 2), 2, 3)

    {exposed_state, rest_stack, start_pos, end_pos, captures} =
      Stack.reduce(stack, production, stream, 3)

    assert exposed_state == 0
    assert rest_stack == [{0, 0, 0, nil}]
    assert {start_pos, end_pos} == {0, 3}
    assert captures == %{n: [{:token, :NUM, "1"}, {:token, :NUM, "2"}]}
  end

  test "push_reduced/5 lands a reduced nonterminal's captures on top, tagged with its target state" do
    stack = Stack.push_reduced([], 7, 0, 3, %{n: "1"})
    assert [{7, 0, 3, %{n: "1"}}] = stack
  end
end
