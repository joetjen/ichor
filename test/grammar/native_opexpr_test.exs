defmodule Grammar.Native.OpExprTest do
  use ExUnit.Case, async: true

  defp vm_grammar do
    source = File.read!(Path.join(__DIR__, "../opexpr/opexpr.aether"))
    {:ok, grammar} = Aether.Parser.parse(source)
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: vm_grammar()}
  end

  # "times" binds tighter than "plus" -- `1 plus 2 times 3` should group
  # as `1 plus (2 times 3)`, proving precedence is actually being read
  # from `context`, not hardcoded anywhere in the grammar.
  describe "precedence read from a mutable context, both backends" do
    setup do
      {:ok,
       context: %{
         operators: %{"plus" => {1, :left}, "times" => {2, :left}, "minus" => {1, :left}}
       }}
    end

    test "native: 1 plus 2 times 3 == 7", %{context: ctx} do
      assert Native.OpExpr.run("1 plus 2 times 3", ctx) == {:ok, 7}
    end

    test "vm: 1 plus 2 times 3 == 7", %{grammar: g, context: ctx} do
      assert Grammar.VM.run(g, "1 plus 2 times 3", OpExprTest.Actions, ctx) == {:ok, 7}
    end

    test "native and vm agree on a left-associative chain: 10 minus 3 minus 2 == 5", %{
      grammar: g,
      context: ctx
    } do
      assert Native.OpExpr.run("10 minus 3 minus 2", ctx) == {:ok, 5}
      assert Grammar.VM.run(g, "10 minus 3 minus 2", OpExprTest.Actions, ctx) == {:ok, 5}
    end

    test "a single number with no operator passes straight through", %{grammar: g, context: ctx} do
      assert Native.OpExpr.run("42", ctx) == {:ok, 42}
      assert Grammar.VM.run(g, "42", OpExprTest.Actions, ctx) == {:ok, 42}
    end
  end

  # Same source, same grammar -- only the operator table living in
  # `context` changes -- and the grouping flips accordingly. This is the
  # actual feature: a static PEG grammar could never express this on its
  # own, since precedence would have to be baked into the rule structure
  # at compile time.
  test "flipping precedence in context flips how the same input groups" do
    low_times = %{operators: %{"plus" => {1, :left}, "times" => {2, :left}}}
    high_plus = %{operators: %{"plus" => {2, :left}, "times" => {1, :left}}}

    assert Native.OpExpr.run("1 plus 2 times 3", low_times) == {:ok, 1 + 2 * 3}
    assert Native.OpExpr.run("1 plus 2 times 3", high_plus) == {:ok, (1 + 2) * 3}
  end

  test "an operator absent from context's table isn't treated as an operator at all" do
    ctx = %{operators: %{"plus" => {1, :left}}}
    assert {:error, _} = Native.OpExpr.run("1 mystery 2", ctx)
  end
end
