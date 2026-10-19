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
  order -- see `t:Ichor.Capture.raw_captures/0`), each value recording
  the tokens `[pos, new_pos)` it matched (`Ichor.Capture.at/3`), so an
  action's error can say where. `context` is read-only,
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

  @doc """
  Compiles every rule into a list of quoted `defp` definitions, one named
  `rule_fn_name/1` per rule plus one per anonymous sub-expression.

  With `lossless: true`, the second set a lossless parser runs instead
  (`lossless_rule_fn_name/1`, `design/lossless-mode.md`): the same
  functions under their own names, but every rule call also records
  itself for `Ichor.Syntax`, under `Ichor.Syntax.Record.key/0`. A set
  of its own rather than a flag in the one set, so the ordinary
  parser's functions are exactly what they were, and nothing on its path
  checks which mode it is in.
  """
  @spec compile(Aether.Grammar.t(), keyword()) :: [Macro.t()]
  def compile(grammar, opts \\ []) do
    env = %{
      token_names: VMRuleCompiler.token_names(grammar),
      anon_tokens: VMRuleCompiler.implicit_capture_exclusions(grammar),
      lossless: Keyword.get(opts, :lossless, false)
    }

    {defs, _counter} =
      Enum.reduce(grammar.rules, {[], 0}, fn {name, ir}, {acc, counter} ->
        {sub_defs, counter} = compile_expr(ir, counter, env, fn_name(name, env))

        {acc ++ sub_defs, counter}
      end)

    defs
  end

  @doc "The generated function name for a given rule name -- exposed so `Grammar.Native` can reference the root rule's own matcher."
  @spec rule_fn_name(atom()) :: atom()
  def rule_fn_name(name), do: :"parse_rule__#{name}"

  @doc "The lossless set's function for a rule (`compile/2` with `lossless: true`)."
  @spec lossless_rule_fn_name(atom()) :: atom()
  def lossless_rule_fn_name(name), do: :"lossless_rule__#{name}"

  # Every name a set calls is its own set's: a lossless function never
  # calls an ordinary one, nor the other way round.
  defp fn_name(name, %{lossless: false}), do: rule_fn_name(name)
  defp fn_name(name, %{lossless: true}), do: lossless_rule_fn_name(name)

  defp fresh_name(counter, %{lossless: false}), do: Codegen.fresh("parse_expr__", counter)
  defp fresh_name(counter, %{lossless: true}), do: Codegen.fresh("lossless_expr__", counter)

  # `env` is what every clause needs to know of the grammar and the set
  # being compiled: `token_names`, `anon_tokens` and `lossless`.
  @typep env :: %{token_names: MapSet.t(), anon_tokens: MapSet.t(), lossless: boolean()}

  @spec compile_expr(IR.expr(), non_neg_integer(), env(), atom() | nil) ::
          {[Macro.t()], non_neg_integer()}

  # ---- leaves: RuleRef/Capture/Indent/Custom (rule-level only) ----------

  defp compile_expr(
         %IR.RuleRef{name: ref_name},
         counter,
         env,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter, env)

    def_ =
      if MapSet.member?(env.anon_tokens, ref_name) do
        bare_token_def(name, ref_name)
      else
        captured_ref_def(name, ref_name, ref_name, env)
      end

    {[def_], counter}
  end

  defp compile_expr(
         %IR.Capture{name: cap_name, expr: %IR.RuleRef{name: ref_name}},
         counter,
         env,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter, env)
    {[captured_ref_def(name, cap_name, ref_name, env)], counter}
  end

  # `@native(...)`, bare or explicitly captured: like a bare `RuleRef`'s
  # implicit self-capture, but there's no rule/token name to reuse, so the
  # callback's own `function` name stands in for it.
  defp compile_expr(
         %IR.Capture{name: cap_name, expr: %IR.Custom{} = custom},
         counter,
         env,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter, env)
    {[custom_def(name, cap_name, custom)], counter}
  end

  defp compile_expr(
         %IR.Custom{function: function} = custom,
         counter,
         env,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter, env)
    {[custom_def(name, function, custom)], counter}
  end

  defp compile_expr(
         %IR.Capture{name: cap_name, expr: inner},
         counter,
         env,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter, env)
    {inner_name, inner_defs, counter} = compile_one(inner, counter, env)

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
               Parser.merge_captures(inner_caps, [
                 {unquote(cap_name), Ichor.Capture.at({:text, text}, unquote(pos), new_pos)}
               ])}

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
         env,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter, env)
    {inner_name, inner_defs, counter} = compile_one(e, counter, env)

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
         env,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter, env)
    {inner_name, inner_defs, counter} = compile_one(e, counter, env)

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

  defp compile_expr(%IR.Seq{exprs: exprs}, counter, env, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter, env)
    {sub_names, sub_defs, counter} = compile_all(exprs, counter, env)

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

  defp compile_expr(%IR.Choice{exprs: [only]}, counter, env, preferred_name),
    do: compile_expr(only, counter, env, preferred_name)

  defp compile_expr(%IR.Choice{exprs: exprs}, counter, env, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter, env)
    {sub_names, sub_defs, counter} = compile_all(exprs, counter, env)

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

  defp compile_expr(%IR.Star{expr: e}, counter, env, preferred_name) do
    unary_combinator(:star, e, counter, env, preferred_name)
  end

  defp compile_expr(%IR.Plus{expr: e}, counter, env, preferred_name) do
    unary_combinator(:plus, e, counter, env, preferred_name)
  end

  defp compile_expr(%IR.Opt{expr: e}, counter, env, preferred_name) do
    unary_combinator(:opt, e, counter, env, preferred_name)
  end

  defp compile_expr(%IR.AndPred{expr: e}, counter, env, preferred_name) do
    unary_combinator(:and_pred, e, counter, env, preferred_name)
  end

  defp compile_expr(%IR.NotPred{expr: e}, counter, env, preferred_name) do
    unary_combinator(:not_pred, e, counter, env, preferred_name)
  end

  defp compile_expr(
         %IR.Rep{expr: e, min: min, max: max},
         counter,
         env,
         preferred_name
       ) do
    {name, counter} = name_or_fresh(preferred_name, counter, env)
    {inner_name, inner_defs, counter} = compile_one(e, counter, env)

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

  defp captured_ref_def(name, cap_name, ref_name, env) do
    stream = Macro.var(:stream, nil)
    pos = Macro.var(:pos, nil)
    ref_stack = Macro.var(:ref_stack, nil)

    if MapSet.member?(env.token_names, ref_name) do
      context = Macro.var(:_context, nil)

      quote do
        defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack), unquote(context)) do
          case Parser.match_token(unquote(stream), unquote(pos), unquote(ref_name)) do
            {:ok, new_pos, text, nil} ->
              {:ok, new_pos, unquote(ref_stack),
               [
                 {unquote(cap_name),
                  Ichor.Capture.at({:token, unquote(ref_name), text}, unquote(pos), new_pos)}
               ]}

            {:ok, new_pos, _text, capture} ->
              {:ok, new_pos, unquote(ref_stack),
               [{unquote(cap_name), Ichor.Capture.at(capture, unquote(pos), new_pos)}]}

            :fail ->
              :fail
          end
        end
      end
    else
      rule_call_def(name, cap_name, ref_name, env)
    end
  end

  defp rule_call_def(name, cap_name, ref_name, %{lossless: false}) do
    %{stream: stream, pos: pos, ref_stack: ref_stack, context: context} =
      Codegen.vars([:stream, :pos, :ref_stack, :context])

    target = rule_fn_name(ref_name)

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
             [
               {unquote(cap_name),
                Ichor.Capture.at({:rule, unquote(ref_name), sub_captures}, unquote(pos), new_pos)}
             ]}

          _fail ->
            :fail
        end
      end
    end
  end

  # The lossless set's rule call: the ordinary `{:rule, ...}` capture,
  # without the callee's records, and the call's own record beside it --
  # holding those records, over the tokens `[pos, new_pos)` it matched.
  defp rule_call_def(name, cap_name, ref_name, %{lossless: true}) do
    %{stream: stream, pos: pos, ref_stack: ref_stack, context: context} =
      Codegen.vars([:stream, :pos, :ref_stack, :context])

    target = lossless_rule_fn_name(ref_name)

    quote do
      defp unquote(name)(unquote(stream), unquote(pos), unquote(ref_stack), unquote(context)) do
        case unquote(target)(
               unquote(stream),
               unquote(pos),
               unquote(ref_stack),
               unquote(context)
             ) do
          {:ok, new_pos, new_ref_stack, sub_captures} ->
            {sub_captures, record} =
              Ichor.Syntax.Record.called(unquote(ref_name), unquote(pos), new_pos, sub_captures)

            {:ok, new_pos, new_ref_stack,
             [
               {unquote(cap_name),
                Ichor.Capture.at({:rule, unquote(ref_name), sub_captures}, unquote(pos), new_pos)},
               {unquote(Ichor.Syntax.Record.key()), record}
             ]}

          _fail ->
            :fail
        end
      end
    end
  end

  # A `@native(...)` rule's matchers call the *ordinary* rule functions,
  # in the lossless set too: the custom code is handed ordinary captures,
  # the rules it matches are not nodes of a lossless tree, and their
  # tokens fall to the node of the rule that called it -- as on the VM.
  #
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
               {:ok, new_pos, _ref_stack, caps} ->
                 {:ok, new_pos, Ichor.Capture.plain({:rule, unquote(dep), caps})}

               :fail ->
                 :fail
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
            {:ok, new_pos, unquote(ref_stack),
             [{unquote(cap_name), Ichor.Capture.at(capture, unquote(pos), new_pos)}]}

          :fail ->
            :fail
        end
      end
    end
  end

  defp unary_combinator(kind, e, counter, env, preferred_name) do
    {name, counter} = name_or_fresh(preferred_name, counter, env)
    {inner_name, inner_defs, counter} = compile_one(e, counter, env)

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

  defp name_or_fresh(nil, counter, env), do: fresh_name(counter, env)
  defp name_or_fresh(name, counter, _env), do: {name, counter}

  defp compile_one(ir, counter, env) do
    {name, counter} = fresh_name(counter, env)
    {defs, counter} = compile_expr(ir, counter, env, name)
    {name, defs, counter}
  end

  defp compile_all(exprs, counter, env) do
    {names, defs, counter} =
      Enum.reduce(exprs, {[], [], counter}, fn e, {names, defs, counter} ->
        {name, sub_defs, counter} = compile_one(e, counter, env)
        {names ++ [name], defs ++ sub_defs, counter}
      end)

    {names, defs, counter}
  end
end
