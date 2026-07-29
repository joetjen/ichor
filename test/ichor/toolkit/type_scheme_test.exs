defmodule Ichor.Toolkit.TypeSchemeTest do
  @moduledoc """
  Proves Ichor.Toolkit.TypeScheme + Ichor.Backtrack.Bindings.unify_occurs_check/4
  via HM.Infer (test/support/hm.ex), a small Hindley-Milner type checker.
  """

  use ExUnit.Case, async: true

  alias Ichor.Backtrack.Bindings
  alias Ichor.Toolkit.{Scope, TypeScheme}
  alias HM.{Infer, Types}

  defp infer!(expr) do
    {:ok, type, bindings} = Infer.infer(expr, Scope.new(), Bindings.new())
    TypeScheme.resolve_deep(Types, bindings, type)
  end

  describe "base types, no polymorphism involved" do
    test "a literal has its own base type" do
      assert infer!({:int, 42}) == Types.int()
      assert infer!({:string, "hi"}) == Types.string()
    end

    test "a lambda's type is param_type -> body_type" do
      assert {:tcon, :->, [{:tvar, _}, {:tcon, :int, []}]} = infer!({:lambda, :x, {:int, 1}})
    end

    test "applying a function unifies the argument with the parameter type" do
      # (fn x -> x) applied to 1 : int
      assert infer!({:apply, {:lambda, :x, {:var, :x}}, {:int, 1}}) == Types.int()
    end

    test "applying a function to the wrong type is a real type error" do
      # (fn x -> x + 1, informally) applied to a string -- modeled here
      # as applying the identity function's *result* through another
      # int-expecting application, since the toy language has no
      # arithmetic: instead, directly mismatch by applying a non-function.
      assert {:error, _} =
               Infer.infer({:apply, {:int, 1}, {:int, 2}}, Scope.new(), Bindings.new())
    end

    test "an undefined variable is an error" do
      assert {:error, message} = Infer.infer({:var, :nope}, Scope.new(), Bindings.new())
      assert message =~ "nope"
    end
  end

  describe "let-polymorphism: the whole point of generalize/instantiate" do
    test "a let-bound identity function is used at two different types in the same body" do
      # let id = fn x -> x in (id 1, id "s")
      program =
        {:let, :id, {:lambda, :x, {:var, :x}},
         {:pair, {:apply, {:var, :id}, {:int, 1}}, {:apply, {:var, :id}, {:string, "s"}}}}

      assert infer!(program) == {:tcon, :pair, [Types.int(), Types.string()]}
    end

    test "a lambda parameter is NOT generalized -- it's monomorphic within its own body" do
      # fn f -> (f 1, f "s") must fail: f's own parameter type is fixed
      # once, it can't be used at two different types the way a let-bound
      # polymorphic function can.
      program =
        {:lambda, :f,
         {:pair, {:apply, {:var, :f}, {:int, 1}}, {:apply, {:var, :f}, {:string, "s"}}}}

      assert {:error, _} = Infer.infer(program, Scope.new(), Bindings.new())
    end
  end

  describe "occurs-check: catches what plain unify/4 would silently accept" do
    test "self-application (fn x -> x x) is an infinite type, correctly rejected" do
      program = {:lambda, :x, {:apply, {:var, :x}, {:var, :x}}}
      assert {:error, _} = Infer.infer(program, Scope.new(), Bindings.new())
    end

    test "the same scenario, unified with plain unify/4 instead, would NOT fail -- this is exactly why the type checker uses unify_occurs_check/4" do
      x = Types.fresh()
      y = Types.fresh()
      cyclic = Types.fn_type(x, y)
      assert {:ok, _bindings} = Bindings.unify(Types, Bindings.new(), x, cyclic)
      assert Bindings.unify_occurs_check(Types, Bindings.new(), x, cyclic) == :fail
    end
  end
end
