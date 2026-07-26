defmodule Grammar.Native.LispTest do
  use ExUnit.Case, async: true

  alias Lisp.Symbol
  alias Support.ExampleGrammars

  defp vm_grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.2 lisp"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  defp vm_bootstrap(grammar) do
    Lisp.Actions.new_context()
    |> Lisp.Primitives.seed()
    |> then(&Lisp.Stdlib.load(grammar, &1))
  end

  # `Lisp.Stdlib.load/2` bootstraps `stdlib.lisp` by calling
  # `Grammar.VM.run_sequence` -- this proves the native backend's own
  # `run_sequence/2` bootstraps `stdlib.lisp` identically.
  defp native_bootstrap do
    ctx = Lisp.Actions.new_context() |> Lisp.Primitives.seed()

    case Native.Lisp.run_sequence(Lisp.Stdlib.source(), ctx) do
      {:ok, _values, final_ctx} ->
        final_ctx

      {:error, error} ->
        raise "failed to load stdlib.lisp via the native backend: #{inspect(error)}"
    end
  end

  setup do
    grammar = vm_grammar()
    {:ok, vm_grammar: grammar, vm_ctx: vm_bootstrap(grammar), native_ctx: native_bootstrap()}
  end

  describe "run/2 parity with the VM backend" do
    for source <- [
          "(if 1 (quote yes) (quote no))",
          "(if false (quote yes) (quote no))",
          "(if 1 42 this-is-unbound)",
          "(let [x 5] (* x x))",
          "(quote (a (b c) 1))",
          "(quote ())",
          "((fn [] 42))",
          "((fn [x] x) 5)",
          ~S|(cond true "first" true "second")|,
          ~S|(cond false "first" false "second")|,
          ~S|(cond true "taken" true unbound-symbol)|,
          "(def x 1)",
          "[1 2 3]",
          "{:a 1}"
        ] do
      test "#{inspect(source)}", %{vm_grammar: g, vm_ctx: vm_ctx, native_ctx: native_ctx} do
        source = unquote(source)

        assert Native.Lisp.run(source, native_ctx) ==
                 Grammar.VM.run(g, source, Lisp.Actions, vm_ctx)
      end
    end
  end

  describe "run_sequence/2 parity with the VM backend (the stdlib-loading bootstrap mechanism)" do
    test "a definition is visible to later top-level forms", %{
      vm_grammar: g,
      vm_ctx: vm_ctx,
      native_ctx: native_ctx
    } do
      source = "(def answer 42)\nanswer\n"

      assert Native.Lisp.run_sequence(source, native_ctx) ==
               Grammar.VM.run_sequence(g, source, Lisp.Actions, vm_ctx)
    end

    test "closures close over their defining context", %{
      vm_grammar: g,
      vm_ctx: vm_ctx,
      native_ctx: native_ctx
    } do
      source = """
      (def add-x (fn [x] (fn [y] (+ x y))))
      ((add-x 3) 5)
      """

      assert Native.Lisp.run_sequence(source, native_ctx) ==
               Grammar.VM.run_sequence(g, source, Lisp.Actions, vm_ctx)
    end

    test "an infinitely-recursive untaken branch is never evaluated on the native backend either",
         %{native_ctx: native_ctx} do
      source = """
      (def loop-forever (fn [] (loop-forever)))
      (if 1 99 (loop-forever))
      """

      assert {:ok, [%Symbol{name: "loop-forever"}, 99], _ctx} =
               Native.Lisp.run_sequence(source, native_ctx)
    end
  end

  test "stdlib.lisp bootstraps to the same macro set on both backends", %{
    vm_ctx: vm_ctx,
    native_ctx: native_ctx
  } do
    assert Map.keys(native_ctx.macros) |> Enum.sort() == Map.keys(vm_ctx.macros) |> Enum.sort()
  end
end
