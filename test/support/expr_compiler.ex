defmodule ExprCompiler do
  @moduledoc """
  A worked example for `Ichor.Toolkit.Codegen`, deliberately unrelated to
  grammars or Ichor's own IR: compiles a tiny expression language
  (`{:num, n}` / `{:var, name}` / `{:add, a, b}` / `{:mul, a, b}` /
  `{:sum, exprs}` / `{:switch, subject, branches}` / `{:map_sum, fn_name,
  list_expr}`) directly into quoted Elixir function definitions, one
  named function per node, composed via direct calls -- the same
  discipline `Grammar.Native.CharCompiler`/`RuleCompiler` use for real
  grammars, proving `Codegen`'s helpers aren't accidentally tied to
  Ichor's own capture-tree/IR shapes.

  Every generated function has the shape `(env :: map()) -> term()`,
  `env` being a plain `name => value` map for `{:var, name}` lookups.
  """

  alias Ichor.Toolkit.Codegen

  @type branch :: {pattern :: term(), guard :: Macro.t() | nil, body :: expr()}
  @type expr ::
          {:num, number()}
          | {:var, atom()}
          | {:add, expr(), expr()}
          | {:mul, expr(), expr()}
          | {:sum, [expr()]}
          | {:switch, expr(), [branch()]}
          | {:map_sum, atom(), expr()}

  @doc "Compiles `expr` into a list of quoted `defp` definitions, the top-level one named `name`."
  @spec compile(expr(), atom()) :: [Macro.t()]
  def compile(expr, name) do
    {defs, _counter} = compile_expr(expr, 0, name)
    defs
  end

  defp fresh_name(counter), do: Codegen.fresh("expr__", counter)

  defp compile_expr({:num, n}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    %{_env: env} = Codegen.vars([:_env])

    def_ =
      quote do
        defp unquote(name)(unquote(env)), do: unquote(n)
      end

    {[def_], counter}
  end

  defp compile_expr({:var, var_name}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    %{env: env} = Codegen.vars([:env])

    def_ =
      quote do
        defp unquote(name)(unquote(env)), do: Map.fetch!(unquote(env), unquote(var_name))
      end

    {[def_], counter}
  end

  defp compile_expr({:add, a, b}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {a_name, a_defs, counter} = compile_one(a, counter)
    {b_name, b_defs, counter} = compile_one(b, counter)
    %{env: env} = Codegen.vars([:env])

    def_ =
      quote do
        defp unquote(name)(unquote(env)) do
          unquote(a_name)(unquote(env)) + unquote(b_name)(unquote(env))
        end
      end

    {a_defs ++ b_defs ++ [def_], counter}
  end

  defp compile_expr({:mul, a, b}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {a_name, a_defs, counter} = compile_one(a, counter)
    {b_name, b_defs, counter} = compile_one(b, counter)
    %{env: env} = Codegen.vars([:env])

    def_ =
      quote do
        defp unquote(name)(unquote(env)) do
          unquote(a_name)(unquote(env)) * unquote(b_name)(unquote(env))
        end
      end

    {a_defs ++ b_defs ++ [def_], counter}
  end

  # N-ary sum: chains an accumulator across the sub-expressions, one
  # intermediate variable per position -- the same shape
  # `Grammar.Native.RuleCompiler`'s `Seq` compilation threads its own
  # `pos`/`ref`/`cap` series through, the motivating case for
  # `indexed_vars/3`.
  defp compile_expr({:sum, exprs}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_names, sub_defs, counter} = compile_all(exprs, counter)
    %{env: env} = Codegen.vars([:env])
    acc_vars = Codegen.indexed_vars(:acc, length(sub_names))

    {assigns, final_acc} =
      [sub_names, acc_vars]
      |> Enum.zip()
      |> Enum.reduce({[], 0}, fn {sub_name, acc_var}, {assigns, prev} ->
        assign =
          quote do
            unquote(acc_var) = unquote(prev) + unquote(sub_name)(unquote(env))
          end

        {assigns ++ [assign], acc_var}
      end)

    def_ =
      quote do
        defp unquote(name)(unquote(env)) do
          unquote_splicing(assigns)
          unquote(final_acc)
        end
      end

    {sub_defs ++ [def_], counter}
  end

  # Dispatches on `subject`'s value via a real `case`, one compiled
  # clause per branch -- `clause/2`/`clause/3` exist precisely because a
  # bare `pattern -> body` can't stand alone as a quoted expression
  # outside `case`/`cond`/`fn`.
  defp compile_expr({:switch, subject, branches}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {subject_name, subject_defs, counter} = compile_one(subject, counter)
    %{env: env} = Codegen.vars([:env])

    {branch_defs, case_clauses, counter} =
      Enum.reduce(branches, {[], [], counter}, fn {pattern, guard, body},
                                                  {defs, clauses, counter} ->
        {body_name, body_defs, counter} = compile_one(body, counter)
        body_call = quote(do: unquote(body_name)(unquote(env)))

        clause =
          case guard do
            nil -> Codegen.clause(pattern, body_call)
            _ -> Codegen.clause(pattern, guard, body_call)
          end

        {defs ++ body_defs, clauses ++ [clause], counter}
      end)

    def_ =
      quote do
        defp unquote(name)(unquote(env)) do
          case unquote(subject_name)(unquote(env)) do
            unquote(case_clauses)
          end
        end
      end

    {subject_defs ++ branch_defs ++ [def_], counter}
  end

  # Applies an arbitrary already-defined arity-1 function (named by a
  # plain runtime atom, e.g. a helper the caller predefines elsewhere in
  # the same module) over the list `list_expr` evaluates to, then sums --
  # the motivating case for `capture/2`: `fn_name` is only known once
  # this node is compiled, so `&fn_name/1` can't be written literally in
  # source.
  defp compile_expr({:map_sum, fn_name, list_expr}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {list_name, list_defs, counter} = compile_one(list_expr, counter)
    %{env: env} = Codegen.vars([:env])

    def_ =
      quote do
        defp unquote(name)(unquote(env)) do
          unquote(list_name)(unquote(env))
          |> Enum.map(unquote(Codegen.capture(fn_name, 1)))
          |> Enum.sum()
        end
      end

    {list_defs ++ [def_], counter}
  end

  defp name_or_fresh(nil, counter), do: fresh_name(counter)
  defp name_or_fresh(name, counter), do: {name, counter}

  defp compile_one(expr, counter) do
    {name, counter} = fresh_name(counter)
    {defs, counter} = compile_expr(expr, counter, name)
    {name, defs, counter}
  end

  defp compile_all(exprs, counter) do
    Enum.reduce(exprs, {[], [], counter}, fn expr, {names, defs, counter} ->
      {name, sub_defs, counter} = compile_one(expr, counter)
      {names ++ [name], defs ++ sub_defs, counter}
    end)
  end
end

defmodule ExprCompiler.Example do
  @moduledoc """
  A single concrete `ExprCompiler` instantiation, spliced into this real
  module via `Code.eval_quoted/3` -- exactly how a real macro-based
  compiler (`use Ichor`, for instance) splices its own generated `defp`s
  into whichever module invokes it, just done directly here since this
  is a plain worked example rather than its own DSL/macro.

  `demo_expr` exercises every `ExprCompiler` node at once: a `:switch`
  on `env.flag` picks between a `:map_sum` (doubling `env.xs` via
  `double/1`, defined below) and a `:sum` of a literal plus an `:add`
  and a `:mul` over `env.a`.
  """

  def double(x), do: x * 2

  demo_expr =
    {:switch, {:var, :flag},
     [
       {true, nil, {:map_sum, :double, {:var, :xs}}},
       {false, nil,
        {:sum, [{:num, 1}, {:add, {:var, :a}, {:num, 2}}, {:mul, {:var, :a}, {:num, 3}}]}}
     ]}

  Code.eval_quoted(
    quote do
      (unquote_splicing(ExprCompiler.compile(demo_expr, :demo)))
    end,
    [],
    __ENV__
  )

  @doc "Runs the demo expression against `env` (`%{flag: bool, xs: [...]} | %{flag: false, a: number}`)."
  def run(env), do: demo(env)
end
