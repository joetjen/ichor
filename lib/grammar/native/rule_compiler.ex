defmodule Grammar.Native.RuleCompiler do
  @moduledoc """
  Compiles every rule in a grammar into quoted Elixir function
  definitions run against the lexer's token stream (never raw
  characters -- Aether's own two-stage split), mirroring
  `Grammar.VM.RuleCompiler`'s own semantics exactly (bare-reference
  implicit self-capture, `Indent`/`@samecol`, capture-shape rules) but
  producing direct function calls instead of bytecode.

  Every generated function has the shape `(stream :: tuple(), pos ::
  non_neg_integer(), ref_stack :: [integer()], context :: term()) ->
  {:ok, new_pos, new_ref_stack, raw_captures} | :fail`, where
  `raw_captures` is exactly the ordered-list shape `Ichor.Actions`
  expects (`{:token, name, text}` / `{:rule, name, sub_captures}` /
  `{:text, text}` values, keyed by name, in first-occurrence RHS
  order -- see `Ichor.Capture.raw_captures/0`). `context` is read-only,
  threaded through purely so a
  `Grammar.IR.Custom` `@native(...)` leaf can hand it to
  `c:Ichor.CustomRule.match/4` -- nothing else in this module ever reads
  it, only passes it along. A `RuleRef` compiles to a call into that
  other rule/token's own compiled function; the grammar's own token/rule
  namespaces (passed in as `token_names`) are what tell the two apart,
  exactly as in the VM.
  """

  alias Grammar.IR
  alias Grammar.Native.Runtime.Parser
  alias Grammar.VM.RuleCompiler, as: VMRuleCompiler
  alias Ichor.Toolkit.Codegen

  @doc "Compiles every rule into a list of quoted `defp` definitions, one named `rule_fn_name/1` per rule plus one per anonymous sub-expression."
  @spec compile(Aether.Grammar.t()) :: [Macro.t()]
  def compile(grammar) do
    token_names = VMRuleCompiler.token_names(grammar)
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

  defp fresh_name(counter), do: Codegen.fresh("parse_expr__", counter)

  @spec compile_expr(IR.expr(), non_neg_integer(), MapSet.t(), MapSet.t(), atom() | nil) ::
          {[Macro.t()], non_neg_integer()}

  # ---- leaves: RuleRef/Capture/Indent/Custom (rule-level only) ----------

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

  # `@native(...)`, bare or explicitly captured: like a bare `RuleRef`'s
  # implicit self-capture, but there's no rule/token name to reuse, so the
  # callback's own `function` name stands in for it.
  defp compile_expr(
         %IR.Capture{name: cap_name, expr: %IR.Custom{} = custom},
         counter,
         _token_names,
         _anon_tokens,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {[custom_def(name, cap_name, custom)], counter}
  end

  defp compile_expr(
         %IR.Custom{function: function} = custom,
         counter,
         _token_names,
         _anon_tokens,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {[custom_def(name, function, custom)], counter}
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

    %{stream: stream, pos: pos, ref_stack: ref_stack, context: context} =
      Codegen.vars([:stream, :pos, :ref_stack, :context])

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack), unquote(context)) do
          case unquote(Codegen.capture(inner_name, 4)).(
                 unquote(stream),
                 unquote(pos),
                 unquote(ref_stack),
                 unquote(context)
               ) do
            {:ok, new_pos, new_ref_stack, inner_caps} ->
              text = Parser.concat_text(unquote(stream), unquote(pos), new_pos)

              {:ok, new_pos, new_ref_stack,
               Parser.merge_captures(inner_caps, [{unquote(cap_name), {:text, text}}])}

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

    %{stream: stream, pos: pos, ref_stack: ref_stack, context: context} =
      Codegen.vars([:stream, :pos, :ref_stack, :context])

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack), unquote(context)) do
          Parser.indent_enter(
            unquote(Codegen.capture(inner_name, 4)),
            unquote(stream),
            unquote(pos),
            unquote(ref_stack),
            unquote(context)
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

    %{stream: stream, pos: pos, ref_stack: ref_stack, context: context} =
      Codegen.vars([:stream, :pos, :ref_stack, :context])

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack), unquote(context)) do
          Parser.samecol_check(
            unquote(Codegen.capture(inner_name, 4)),
            unquote(stream),
            unquote(pos),
            unquote(ref_stack),
            unquote(context)
          )
        end
      end

    {inner_defs ++ [def_], counter}
  end

  # ---- combinators (shared shape with the char level) -------------------

  defp compile_expr(%IR.Seq{exprs: exprs}, counter, token_names, anon_tokens, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {sub_names, sub_defs, counter} = compile_all(exprs, counter, token_names, anon_tokens)

    %{stream: stream, pos: pos0, ref_stack: ref0, context: context} =
      Codegen.vars([:stream, :pos, :ref_stack, :context])

    pos_vars = Codegen.indexed_vars(:pos, length(sub_names), 1)
    ref_vars = Codegen.indexed_vars(:ref, length(sub_names), 1)
    cap_vars = Codegen.indexed_vars(:cap, length(sub_names))

    {clauses, final_pos, final_ref} =
      [sub_names, pos_vars, ref_vars, cap_vars]
      |> Enum.zip()
      |> Enum.reduce({[], pos0, ref0}, fn {sub_name, pos_var, ref_var, cap_var},
                                          {clauses, cur_pos, cur_ref} ->
        clause =
          quote do
            {:ok, unquote(pos_var), unquote(ref_var), unquote(cap_var)} <-
              unquote(sub_name)(
                unquote(stream),
                unquote(cur_pos),
                unquote(cur_ref),
                unquote(context)
              )
          end

        {clauses ++ [clause], pos_var, ref_var}
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
        defp unquote(name)(unquote(stream), unquote(pos0), unquote(ref0), unquote(context)) do
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

    %{stream: stream, pos: pos, ref_stack: ref_stack, context: context} =
      Codegen.vars([:stream, :pos, :ref_stack, :context])

    funs = Enum.map(sub_names, &Codegen.capture(&1, 4))

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack), unquote(context)) do
          Parser.try_alts(
            unquote(funs),
            unquote(stream),
            unquote(pos),
            unquote(ref_stack),
            unquote(context)
          )
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

    %{stream: stream, pos: pos, ref_stack: ref_stack, context: context} =
      Codegen.vars([:stream, :pos, :ref_stack, :context])

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack), unquote(context)) do
          Parser.rep(
            unquote(Codegen.capture(inner_name, 4)),
            unquote(min),
            unquote(max),
            unquote(stream),
            unquote(pos),
            unquote(ref_stack),
            unquote(context)
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
    context = Macro.var(:_context, nil)

    quote do
      defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack), unquote(context)) do
        case Parser.match_token(unquote(stream), unquote(pos), unquote(token_name)) do
          {:ok, new_pos, _text, _capture} -> {:ok, new_pos, unquote(ref_stack), []}
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
      context = Macro.var(:_context, nil)

      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack), unquote(context)) do
          case Parser.match_token(unquote(stream), unquote(pos), unquote(ref_name)) do
            {:ok, new_pos, text, nil} ->
              {:ok, new_pos, unquote(ref_stack),
               [{unquote(cap_name), {:token, unquote(ref_name), text}}]}

            {:ok, new_pos, _text, capture} ->
              {:ok, new_pos, unquote(ref_stack), [{unquote(cap_name), capture}]}

            :fail ->
              :fail
          end
        end
      end
    else
      target = rule_fn_name(ref_name)
      context = Macro.var(:context, nil)

      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack), unquote(context)) do
          case unquote(target)(
                 unquote(stream),
                 unquote(pos),
                 unquote(ref_stack),
                 unquote(context)
               ) do
            {:ok, new_pos, new_ref_stack, sub_captures} ->
              {:ok, new_pos, new_ref_stack,
               [{unquote(cap_name), {:rule, unquote(ref_name), sub_captures}}]}

            _fail ->
              :fail
          end
        end
      end
    end
  end

  # `rule_matchers` closures are 2-arity ((stream, pos) -> ...), per
  # `Ichor.CustomRule` -- each one closes over *this* call's own
  # `ref_stack`/`context` rather than taking them as extra arguments, so
  # the callback module never has to know either exists.
  defp custom_def(name, cap_name, %IR.Custom{module: module, function: function, deps: deps}) do
    stream = Macro.var(:stream, nil)
    pos = Macro.var(:pos, nil)
    ref_stack = Macro.var(:ref_stack, nil)
    context = Macro.var(:context, nil)

    matcher_entries =
      Enum.map(deps, fn dep ->
        dep_fn = rule_fn_name(dep)

        quote do
          {unquote(dep),
           fn s, p ->
             case unquote(dep_fn)(s, p, unquote(ref_stack), unquote(context)) do
               {:ok, new_pos, _ref_stack, caps} -> {:ok, new_pos, {:rule, unquote(dep), caps}}
               :fail -> :fail
             end
           end}
        end
      end)

    quote do
      defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack), unquote(context)) do
        rule_matchers = Map.new([unquote_splicing(matcher_entries)])

        case apply(unquote(module), unquote(function), [
               unquote(stream),
               unquote(pos),
               unquote(context),
               rule_matchers
             ]) do
          {:ok, new_pos, capture} ->
            {:ok, new_pos, unquote(ref_stack), [{unquote(cap_name), capture}]}

          :fail ->
            :fail
        end
      end
    end
  end

  defp unary_combinator(kind, e, counter, token_names, anon_tokens, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter)
    {inner_name, inner_defs, counter} = compile_one(e, counter, token_names, anon_tokens)

    %{stream: stream, pos: pos, ref_stack: ref_stack, context: context} =
      Codegen.vars([:stream, :pos, :ref_stack, :context])

    def_ =
      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack), unquote(context)) do
          Parser.unquote(kind)(
            unquote(Codegen.capture(inner_name, 4)),
            unquote(stream),
            unquote(pos),
            unquote(ref_stack),
            unquote(context)
          )
        end
      end

    {inner_defs ++ [def_], counter}
  end

  defp merge_all([one]), do: one

  defp merge_all([first | rest]),
    do: quote(do: Parser.merge_captures(unquote(first), unquote(merge_all(rest))))

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
