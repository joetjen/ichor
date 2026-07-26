defmodule Lisp.ActionsTest do
  use ExUnit.Case, async: true

  alias Lisp.{Keyword, Symbol, Vector}
  alias Support.ExampleGrammars

  defp grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.2 lisp"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  # Layer 1 + Layer 2 of the three-layer bootstrap:
  # Elixir-native primitives, then stdlib.lisp's if/let macros -- the
  # starting context every test below evaluates its program against.
  defp bootstrap_context(grammar) do
    Lisp.Actions.new_context()
    |> Lisp.Primitives.seed()
    |> then(&Lisp.Stdlib.load(grammar, &1))
  end

  setup do
    grammar = grammar()
    {:ok, grammar: grammar, ctx: bootstrap_context(grammar)}
  end

  defp run(grammar, ctx, source) do
    Grammar.VM.run(grammar, source, Lisp.Actions, ctx)
  end

  defp run_sequence(grammar, ctx, source) do
    Grammar.VM.run_sequence(grammar, source, Lisp.Actions, ctx)
  end

  describe "quote" do
    test "a symbol reifies without being evaluated (looked up)", %{grammar: g, ctx: ctx} do
      assert {:ok, %Symbol{name: "unbound-thing"}} = run(g, ctx, "(quote unbound-thing)")
    end

    test "reader-macro sugar '_ is equivalent to (quote _)", %{grammar: g, ctx: ctx} do
      assert {:ok, %Symbol{name: "yes"}} = run(g, ctx, "'yes")
    end

    test "a nested list reifies recursively, not just one level deep", %{grammar: g, ctx: ctx} do
      assert {:ok, [%Symbol{name: "a"}, [%Symbol{name: "b"}, %Symbol{name: "c"}], 1]} =
               run(g, ctx, "(quote (a (b c) 1))")
    end

    test "quoting the empty list", %{grammar: g, ctx: ctx} do
      assert {:ok, []} = run(g, ctx, "(quote ())")
    end
  end

  describe "fn / closures" do
    test "a zero-arg closure applies with no arguments", %{grammar: g, ctx: ctx} do
      assert {:ok, 42} = run(g, ctx, "((fn [] 42))")
    end

    test "params bind and are visible in the body", %{grammar: g, ctx: ctx} do
      assert {:ok, 5} = run(g, ctx, "((fn [x] x) 5)")
    end

    test "closures close over their defining context", %{grammar: g, ctx: ctx} do
      assert {:ok, [%Symbol{name: "add-x"}, 8], _ctx} =
               run_sequence(g, ctx, """
               (def add-x (fn [x] (fn [y] (+ x y))))
               ((add-x 3) 5)
               """)
    end
  end

  describe "def" do
    test "a definition is visible to later top-level forms via run_sequence", %{
      grammar: g,
      ctx: ctx
    } do
      assert {:ok, [%Symbol{name: "answer"}, 42], _ctx} =
               run_sequence(g, ctx, """
               (def answer 42)
               answer
               """)
    end

    test "def's own value is the defined symbol, not the bound value", %{grammar: g, ctx: ctx} do
      assert {:ok, %Symbol{name: "x"}} = run(g, ctx, "(def x 1)")
    end
  end

  describe "cond" do
    test "the first truthy test's expr is the result", %{grammar: g, ctx: ctx} do
      assert {:ok, "first"} = run(g, ctx, ~S|(cond true "first" true "second")|)
    end

    test "falls through to the next pair when a test is false", %{grammar: g, ctx: ctx} do
      assert {:ok, "second"} = run(g, ctx, ~S|(cond false "first" true "second")|)
    end

    test "no matching test yields nil", %{grammar: g, ctx: ctx} do
      assert {:ok, nil} = run(g, ctx, ~S|(cond false "first" false "second")|)
    end

    test "an untaken branch's error never surfaces", %{grammar: g, ctx: ctx} do
      assert {:ok, "taken"} = run(g, ctx, ~S|(cond true "taken" true unbound-symbol)|)
    end
  end

  describe "defmacro" do
    test "a user-defined macro expands and evaluates in the caller's context", %{
      grammar: g,
      ctx: ctx
    } do
      assert {:ok, [%Symbol{name: "my-if"}, "yes"], _ctx} =
               run_sequence(g, ctx, """
               (defmacro my-if (test then else) (list 'cond test then 1 else))
               (my-if true "yes" "no")
               """)
    end
  end

  describe "stdlib if" do
    test "the stdlib if worked example: (if 1 (quote yes) (quote no)) => yes", %{
      grammar: g,
      ctx: ctx
    } do
      assert {:ok, %Symbol{name: "yes"}} = run(g, ctx, "(if 1 (quote yes) (quote no))")
    end

    test "false takes the else branch", %{grammar: g, ctx: ctx} do
      assert {:ok, %Symbol{name: "no"}} = run(g, ctx, "(if false (quote yes) (quote no))")
    end

    test "an unbound symbol in the untaken branch is never evaluated", %{grammar: g, ctx: ctx} do
      assert {:ok, 42} = run(g, ctx, "(if 1 42 this-is-unbound)")
    end

    test "an infinitely-recursive untaken branch is never evaluated (does not hang)", %{
      grammar: g,
      ctx: ctx
    } do
      assert {:ok, [%Symbol{name: "loop-forever"}, 99], _ctx} =
               run_sequence(g, ctx, """
               (def loop-forever (fn [] (loop-forever)))
               (if 1 99 (loop-forever))
               """)
    end
  end

  describe "stdlib let" do
    test "the stdlib let worked example: (let [x 5] (* x x)) => 25", %{grammar: g, ctx: ctx} do
      assert {:ok, 25} = run(g, ctx, "(let [x 5] (* x x))")
    end
  end

  describe "vector and map literals" do
    test "a vector evaluates its contents", %{grammar: g, ctx: ctx} do
      assert {:ok, %Vector{items: [1, 2, 3]}} = run(g, ctx, "[1 2 3]")
    end

    test "a map evaluates keys and values", %{grammar: g, ctx: ctx} do
      assert {:ok, %Lisp.Map{pairs: %{%Keyword{name: "a"} => 1}}} = run(g, ctx, "{:a 1}")
    end
  end
end
