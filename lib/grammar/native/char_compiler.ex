defmodule Grammar.Native.CharCompiler do
  @moduledoc """
  Compiles every token in a grammar (character-level: `Literal`,
  `CharClass`, `Any`, `RuleRef` to another token, and the combinators
  `Seq`/`Choice`/`Star`/`Plus`/`Opt`/`Rep`/`AndPred`/`NotPred` -- the
  same shapes `Grammar.VM.CharCompiler` compiles) into quoted Elixir
  function definitions instead of bytecode.

  Every generated function has the shape `(input :: binary) -> {:ok,
  text :: binary, rest :: binary} | :fail`. Each IR node gets its own
  named function (a declared token's own name for its top-level node,
  a fresh counter-based name for every anonymous sub-expression) --
  composed via direct function calls, never inline-threaded variables
  spliced across separately-quoted fragments, which sidesteps Elixir
  macro hygiene entirely for everything except the handful of
  combinators (`Seq`'s chain) that must build a call sequence whose
  length isn't known until compile time; those use `Macro.var(name,
  nil)` explicitly so every fragment agrees on the same variable.
  """

  alias Grammar.IR
  alias Grammar.Native.Runtime

  @doc "Compiles every declared token into a list of quoted `defp` definitions, one named `token_fn_name/1` per token plus one per anonymous sub-expression."
  @spec compile(%{atom() => IR.expr()}) :: [Macro.t()]
  def compile(tokens) do
    {defs, _counter} =
      Enum.reduce(tokens, {[], 0}, fn {name, ir}, {acc, counter} ->
        {sub_defs, counter} = compile_expr(ir, counter, fn_name(name))
        {acc ++ sub_defs, counter}
      end)

    defs
  end

  @doc "The generated function name for a given token name -- exposed so `Grammar.Native` can reference a token's own matcher when generating the lexer's maximal-munch driver."
  @spec fn_name(atom()) :: atom()
  def fn_name(name), do: :"lex_token__#{name}"

  defp fresh_name(counter), do: {:"lex_expr__#{counter}", counter + 1}

  # `quote do: &unquote(name)/1` does NOT build a valid function-capture
  # AST when `name` is a plain runtime atom -- it splices the atom
  # straight into the `/` node's left slot (`{:/, _, [:foo, 1]}`) instead
  # of the identifier-shaped node `&name/1` actually requires
  # (`{:/, _, [{:foo, [], nil}, 1]}`), so ordinary `quote`/`unquote`
  # can't express "capture this dynamically-named local function" --
  # the AST has to be built directly.
  defp capture_fn(name, arity), do: {:&, [], [{:/, [], [{name, [], nil}, arity]}]}

  # Returns {defs, counter}. `preferred_name` is used for this node's own
  # function (the token's own name at the top level); every recursive
  # sub-call picks a fresh anonymous name instead.
  @spec compile_expr(IR.expr(), non_neg_integer(), atom() | nil) ::
          {[Macro.t()], non_neg_integer()}
  defp compile_expr(%IR.Literal{value: v}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    input = Macro.var(:input, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(input)) do
          case unquote(input) do
            <<unquote(v), rest::binary>> -> {:ok, unquote(v), rest}
            _ -> :fail
          end
        end
      end

    {[def_], counter}
  end

  defp compile_expr(%IR.CharClass{ranges: ranges}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    input = Macro.var(:input, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(input)) do
          case unquote(input) do
            <<c::utf8, rest::binary>> ->
              if Runtime.in_ranges?(c, unquote(ranges)) do
                {:ok, <<c::utf8>>, rest}
              else
                :fail
              end

            _ ->
              :fail
          end
        end
      end

    {[def_], counter}
  end

  defp compile_expr(%IR.Any{}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    input = Macro.var(:input, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(input)) do
          case unquote(input) do
            <<c::utf8, rest::binary>> -> {:ok, <<c::utf8>>, rest}
            _ -> :fail
          end
        end
      end

    {[def_], counter}
  end

  defp compile_expr(%IR.RuleRef{name: ref_name}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    input = Macro.var(:input, nil)
    target = fn_name(ref_name)

    def_ =
      quote do
        defp unquote(name)(unquote(input)), do: unquote(target)(unquote(input))
      end

    {[def_], counter}
  end

  defp compile_expr(%IR.Seq{exprs: exprs}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_names, sub_defs, counter} = compile_all(exprs, counter)

    input0 = Macro.var(:input0, nil)

    {clauses, final_rest, text_vars} =
      Enum.reduce(Enum.with_index(sub_names), {[], input0, []}, fn {sub_name, i},
                                                                   {clauses, cur_input, texts} ->
        text_var = Macro.var(:"t#{i}", nil)
        rest_var = Macro.var(:"rest#{i}", nil)

        clause =
          quote do
            {:ok, unquote(text_var), unquote(rest_var)} <- unquote(sub_name)(unquote(cur_input))
          end

        {clauses ++ [clause], rest_var, texts ++ [text_var]}
      end)

    body =
      quote do
        with unquote_splicing(clauses) do
          {:ok, unquote(join_texts(text_vars)), unquote(final_rest)}
        else
          :fail -> :fail
        end
      end

    def_ =
      quote do
        defp unquote(name)(unquote(input0)) do
          unquote(body)
        end
      end

    {sub_defs ++ [def_], counter}
  end

  defp compile_expr(%IR.Choice{exprs: [only]}, counter, preferred_name),
    do: compile_expr(only, counter, preferred_name)

  defp compile_expr(%IR.Choice{exprs: exprs}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_names, sub_defs, counter} = compile_all(exprs, counter)
    input = Macro.var(:input, nil)

    funs = Enum.map(sub_names, &capture_fn(&1, 1))

    def_ =
      quote do
        defp unquote(name)(unquote(input)) do
          Runtime.first_char_match(unquote(funs), unquote(input))
        end
      end

    {sub_defs ++ [def_], counter}
  end

  defp compile_expr(%IR.Star{expr: e}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_name, sub_defs, counter} = compile_one(e, counter)
    input = Macro.var(:input, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(input)) do
          Runtime.star_char(unquote(capture_fn(sub_name, 1)), unquote(input))
        end
      end

    {sub_defs ++ [def_], counter}
  end

  defp compile_expr(%IR.Plus{expr: e}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_name, sub_defs, counter} = compile_one(e, counter)
    input = Macro.var(:input, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(input)) do
          Runtime.plus_char(unquote(capture_fn(sub_name, 1)), unquote(input))
        end
      end

    {sub_defs ++ [def_], counter}
  end

  defp compile_expr(%IR.Opt{expr: e}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_name, sub_defs, counter} = compile_one(e, counter)
    input = Macro.var(:input, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(input)) do
          Runtime.opt_char(unquote(capture_fn(sub_name, 1)), unquote(input))
        end
      end

    {sub_defs ++ [def_], counter}
  end

  defp compile_expr(%IR.Rep{expr: e, min: min, max: :infinity}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_name, sub_defs, counter} = compile_one(e, counter)
    input = Macro.var(:input, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(input)) do
          Runtime.rep_char(
            unquote(capture_fn(sub_name, 1)),
            unquote(min),
            :infinity,
            unquote(input)
          )
        end
      end

    {sub_defs ++ [def_], counter}
  end

  defp compile_expr(%IR.Rep{expr: e, min: min, max: max}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_name, sub_defs, counter} = compile_one(e, counter)
    input = Macro.var(:input, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(input)) do
          Runtime.rep_char(
            unquote(capture_fn(sub_name, 1)),
            unquote(min),
            unquote(max),
            unquote(input)
          )
        end
      end

    {sub_defs ++ [def_], counter}
  end

  defp compile_expr(%IR.AndPred{expr: e}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_name, sub_defs, counter} = compile_one(e, counter)
    input = Macro.var(:input, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(input)) do
          Runtime.and_pred_char(unquote(capture_fn(sub_name, 1)), unquote(input))
        end
      end

    {sub_defs ++ [def_], counter}
  end

  defp compile_expr(%IR.NotPred{expr: e}, counter, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_name, sub_defs, counter} = compile_one(e, counter)
    input = Macro.var(:input, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(input)) do
          Runtime.not_pred_char(unquote(capture_fn(sub_name, 1)), unquote(input))
        end
      end

    {sub_defs ++ [def_], counter}
  end

  defp name_or_fresh(nil, counter), do: fresh_name(counter)
  defp name_or_fresh(name, counter), do: {name, counter}

  # Compiles a sub-expression with no preferred name, returning just its
  # own (fresh) function name alongside its defs.
  defp compile_one(ir, counter) do
    {name, counter} = fresh_name(counter)
    {defs, counter} = compile_expr(ir, counter, name)
    {name, defs, counter}
  end

  defp compile_all(exprs, counter) do
    {names, defs, counter} =
      Enum.reduce(exprs, {[], [], counter}, fn e, {names, defs, counter} ->
        {name, sub_defs, counter} = compile_one(e, counter)
        {names ++ [name], defs ++ sub_defs, counter}
      end)

    {names, defs, counter}
  end

  defp join_texts([one]), do: one
  defp join_texts([first | rest]), do: quote(do: unquote(first) <> unquote(join_texts(rest)))
end
