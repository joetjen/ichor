defmodule Grammar.Native.RuleCompiler do
  @moduledoc """
  Compiles every rule in a grammar into quoted Elixir function
  definitions run against the lexer's token stream (never raw
  characters -- Aether's own two-stage split), mirroring
  `Grammar.VM.RuleCompiler`'s own semantics exactly (bare-reference
  implicit self-capture, `Indent`/`@samecol`, capture-shape rules) but
  producing direct function calls instead of bytecode.

  Every generated function has the shape `(stream :: tuple(), pos ::
  non_neg_integer(), ref_stack :: [integer()]) -> {:ok, new_pos,
  new_ref_stack, raw_captures} | :fail`, where `raw_captures` is exactly
  the map shape `Ichor.Actions` expects (`{:token, name, text}` /
  `{:rule, name, sub_captures}` / `{:text, text}`). A `RuleRef` compiles
  to a call into that other rule/token's own compiled function; the
  grammar's own token/rule namespaces (passed in as `token_names`) are
  what tell the two apart, exactly as in the VM.
  """

  alias Grammar.IR
  alias Grammar.Native.Runtime
  alias Grammar.VM.RuleCompiler, as: VMRuleCompiler

  @doc "Compiles every rule into a list of quoted `defp` definitions, one named `rule_fn_name/1` per rule plus one per anonymous sub-expression."
  @spec compile(Aether.Grammar.t()) :: [Macro.t()]
  def compile(grammar) do
    token_names = MapSet.new(Map.keys(grammar.tokens))
    anon_tokens = VMRuleCompiler.implicit_capture_exclusions(grammar)

    {defs, _counter} =
      Enum.reduce(grammar.rules, {[], 0}, fn {name, ir}, {acc, counter} ->
        {sub_defs, counter} =
          compile_expr(ir, counter, token_names, anon_tokens, rule_fn_name(name))

        {acc ++ sub_defs, counter}
      end)

    defs
  end

  @doc "The generated function name for a given rule name -- exposed so `Grammar.Native` can reference the root rule's own matcher."
  @spec rule_fn_name(atom()) :: atom()
  def rule_fn_name(name), do: :"parse_rule__#{name}"

  defp fresh_name(counter), do: {:"parse_expr__#{counter}", counter + 1}

  # See `Grammar.Native.CharCompiler`'s own note: `&name/arity` capture
  # syntax can't be built via `quote`/`unquote` when `name` is a plain
  # runtime atom, so the AST is constructed directly.
  defp capture_fn(name, arity), do: {:&, [], [{:/, [], [{name, [], nil}, arity]}]}

  @spec compile_expr(IR.expr(), non_neg_integer(), MapSet.t(), MapSet.t(), atom() | nil) ::
          {[Macro.t()], non_neg_integer()}

  # ---- leaves: RuleRef/Capture/Indent (rule-level only) -----------------

  defp compile_expr(
         %IR.RuleRef{name: ref_name},
         counter,
         token_names,
         anon_tokens,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter)

    def_ =
      if MapSet.member?(anon_tokens, ref_name) do
        bare_token_def(name, ref_name)
      else
        captured_ref_def(name, ref_name, ref_name, token_names)
      end

    {[def_], counter}
  end

  defp compile_expr(
         %IR.Capture{name: cap_name, expr: %IR.RuleRef{name: ref_name}},
         counter,
         token_names,
         _anon_tokens,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {[captured_ref_def(name, cap_name, ref_name, token_names)], counter}
  end

  defp compile_expr(
         %IR.Capture{name: cap_name, expr: inner},
         counter,
         token_names,
         anon_tokens,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {inner_name, inner_defs, counter} = compile_one(inner, counter, token_names, anon_tokens)
    stream = Macro.var(:stream, nil)
    pos = Macro.var(:pos, nil)
    ref_stack = Macro.var(:ref_stack, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack)) do
          case unquote(capture_fn(inner_name, 3)).(
                 unquote(stream),
                 unquote(pos),
                 unquote(ref_stack)
               ) do
            {:ok, new_pos, new_ref_stack, inner_caps} ->
              text = Runtime.concat_text(unquote(stream), unquote(pos), new_pos)

              {:ok, new_pos, new_ref_stack,
               Runtime.merge_captures(inner_caps, %{unquote(cap_name) => {:text, text}})}

            # A wildcard, not a literal `:fail` pattern: when the compiler
            # can prove `inner_name`'s generated function always succeeds
            # (e.g. it's `Opt`-wrapped), matching the literal atom `:fail`
            # here would be flagged as unreachable dead code. `_fail`
            # means the same thing without tripping that check.
            _fail ->
              :fail
          end
        end
      end

    {inner_defs ++ [def_], counter}
  end

  defp compile_expr(
         %IR.Indent{expr: e, kind: :indent},
         counter,
         token_names,
         anon_tokens,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {inner_name, inner_defs, counter} = compile_one(e, counter, token_names, anon_tokens)
    stream = Macro.var(:stream, nil)
    pos = Macro.var(:pos, nil)
    ref_stack = Macro.var(:ref_stack, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack)) do
          Runtime.indent_enter(
            unquote(capture_fn(inner_name, 3)),
            unquote(stream),
            unquote(pos),
            unquote(ref_stack)
          )
        end
      end

    {inner_defs ++ [def_], counter}
  end

  defp compile_expr(
         %IR.Indent{expr: e, kind: :samecol},
         counter,
         token_names,
         anon_tokens,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {inner_name, inner_defs, counter} = compile_one(e, counter, token_names, anon_tokens)
    stream = Macro.var(:stream, nil)
    pos = Macro.var(:pos, nil)
    ref_stack = Macro.var(:ref_stack, nil)

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack)) do
          Runtime.samecol_check(
            unquote(capture_fn(inner_name, 3)),
            unquote(stream),
            unquote(pos),
            unquote(ref_stack)
          )
        end
      end

    {inner_defs ++ [def_], counter}
  end

  # ---- combinators (shared shape with the char level) -------------------

  defp compile_expr(%IR.Seq{exprs: exprs}, counter, token_names, anon_tokens, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_names, sub_defs, counter} = compile_all(exprs, counter, token_names, anon_tokens)

    stream = Macro.var(:stream, nil)
    pos0 = Macro.var(:pos0, nil)
    ref0 = Macro.var(:ref0, nil)

    {clauses, final_pos, final_ref, cap_vars} =
      Enum.reduce(Enum.with_index(sub_names), {[], pos0, ref0, []}, fn {sub_name, i},
                                                                       {clauses, cur_pos, cur_ref,
                                                                        caps} ->
        pos_var = Macro.var(:"pos#{i + 1}", nil)
        ref_var = Macro.var(:"ref#{i + 1}", nil)
        cap_var = Macro.var(:"cap#{i}", nil)

        clause =
          quote do
            {:ok, unquote(pos_var), unquote(ref_var), unquote(cap_var)} <-
              unquote(sub_name)(unquote(stream), unquote(cur_pos), unquote(cur_ref))
          end

        {clauses ++ [clause], pos_var, ref_var, caps ++ [cap_var]}
      end)

    body =
      quote do
        with unquote_splicing(clauses) do
          {:ok, unquote(final_pos), unquote(final_ref), unquote(merge_all(cap_vars))}
        else
          _fail -> :fail
        end
      end

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos0), unquote(ref0)) do
          unquote(body)
        end
      end

    {sub_defs ++ [def_], counter}
  end

  defp compile_expr(%IR.Choice{exprs: [only]}, counter, token_names, anon_tokens, preferred_name),
    do: compile_expr(only, counter, token_names, anon_tokens, preferred_name)

  defp compile_expr(%IR.Choice{exprs: exprs}, counter, token_names, anon_tokens, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_names, sub_defs, counter} = compile_all(exprs, counter, token_names, anon_tokens)
    {stream, pos, ref_stack} = srp()

    funs = Enum.map(sub_names, &capture_fn(&1, 3))

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack)) do
          Runtime.try_alts(unquote(funs), unquote(stream), unquote(pos), unquote(ref_stack))
        end
      end

    {sub_defs ++ [def_], counter}
  end

  defp compile_expr(%IR.Star{expr: e}, counter, token_names, anon_tokens, preferred_name) do
    unary_combinator(:star, e, counter, token_names, anon_tokens, preferred_name)
  end

  defp compile_expr(%IR.Plus{expr: e}, counter, token_names, anon_tokens, preferred_name) do
    unary_combinator(:plus, e, counter, token_names, anon_tokens, preferred_name)
  end

  defp compile_expr(%IR.Opt{expr: e}, counter, token_names, anon_tokens, preferred_name) do
    unary_combinator(:opt, e, counter, token_names, anon_tokens, preferred_name)
  end

  defp compile_expr(%IR.AndPred{expr: e}, counter, token_names, anon_tokens, preferred_name) do
    unary_combinator(:and_pred, e, counter, token_names, anon_tokens, preferred_name)
  end

  defp compile_expr(%IR.NotPred{expr: e}, counter, token_names, anon_tokens, preferred_name) do
    unary_combinator(:not_pred, e, counter, token_names, anon_tokens, preferred_name)
  end

  defp compile_expr(
         %IR.Rep{expr: e, min: min, max: max},
         counter,
         token_names,
         anon_tokens,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {inner_name, inner_defs, counter} = compile_one(e, counter, token_names, anon_tokens)
    {stream, pos, ref_stack} = srp()

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack)) do
          Runtime.rep(
            unquote(capture_fn(inner_name, 3)),
            unquote(min),
            unquote(max),
            unquote(stream),
            unquote(pos),
            unquote(ref_stack)
          )
        end
      end

    {inner_defs ++ [def_], counter}
  end

  # ---- shared helpers --------------------------------------------------

  defp bare_token_def(name, token_name) do
    stream = Macro.var(:stream, nil)
    pos = Macro.var(:pos, nil)
    ref_stack = Macro.var(:ref_stack, nil)

    quote do
      defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack)) do
        case Runtime.match_token(unquote(stream), unquote(pos), unquote(token_name)) do
          {:ok, new_pos, _text} -> {:ok, new_pos, unquote(ref_stack), %{}}
          :fail -> :fail
        end
      end
    end
  end

  defp captured_ref_def(name, cap_name, ref_name, token_names) do
    stream = Macro.var(:stream, nil)
    pos = Macro.var(:pos, nil)
    ref_stack = Macro.var(:ref_stack, nil)

    if MapSet.member?(token_names, ref_name) do
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack)) do
          case Runtime.match_token(unquote(stream), unquote(pos), unquote(ref_name)) do
            {:ok, new_pos, text} ->
              {:ok, new_pos, unquote(ref_stack),
               %{unquote(cap_name) => {:token, unquote(ref_name), text}}}

            :fail ->
              :fail
          end
        end
      end
    else
      target = rule_fn_name(ref_name)

      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack)) do
          case unquote(target)(unquote(stream), unquote(pos), unquote(ref_stack)) do
            {:ok, new_pos, new_ref_stack, sub_captures} ->
              {:ok, new_pos, new_ref_stack,
               %{unquote(cap_name) => {:rule, unquote(ref_name), sub_captures}}}

            _fail ->
              :fail
          end
        end
      end
    end
  end

  defp unary_combinator(kind, e, counter, token_names, anon_tokens, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {inner_name, inner_defs, counter} = compile_one(e, counter, token_names, anon_tokens)
    {stream, pos, ref_stack} = srp()

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack)) do
          Runtime.unquote(kind)(
            unquote(capture_fn(inner_name, 3)),
            unquote(stream),
            unquote(pos),
            unquote(ref_stack)
          )
        end
      end

    {inner_defs ++ [def_], counter}
  end

  defp srp, do: {Macro.var(:stream, nil), Macro.var(:pos, nil), Macro.var(:ref_stack, nil)}

  defp merge_all([one]), do: one

  defp merge_all([first | rest]),
    do: quote(do: Runtime.merge_captures(unquote(first), unquote(merge_all(rest))))

  defp name_or_fresh(nil, counter), do: fresh_name(counter)
  defp name_or_fresh(name, counter), do: {name, counter}

  defp compile_one(ir, counter, token_names, anon_tokens) do
    {name, counter} = fresh_name(counter)
    {defs, counter} = compile_expr(ir, counter, token_names, anon_tokens, name)
    {name, defs, counter}
  end

  defp compile_all(exprs, counter, token_names, anon_tokens) do
    {names, defs, counter} =
      Enum.reduce(exprs, {[], [], counter}, fn e, {names, defs, counter} ->
        {name, sub_defs, counter} = compile_one(e, counter, token_names, anon_tokens)
        {names ++ [name], defs ++ sub_defs, counter}
      end)

    {names, defs, counter}
  end
end
