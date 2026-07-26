defmodule Ichor.Actions do
  @moduledoc """
  How a parsed Aether AST turns into an actual result -- a sandboxed
  program's final value, a config's map/struct, a query's result set, or
  transpiled output. One mechanism, used differently per grammar: a
  grammar's Actions module only implements the rules/tokens it needs
  custom behavior for (`@optional_callbacks`); everything else falls back
  to the defaults below.

  `handle_rule`/`handle_token` are never invoked directly by user code --
  `Grammar.VM` builds the raw capture tree during matching, and this
  module's `evaluate/5` walks it, calling into the actions module (or the
  default fallback) as it goes, threading `context` throughout.
  """

  alias Ichor.{Capture, Error, Node}

  @type context :: term()
  @type captures :: %{optional(atom()) => Capture.t() | [Capture.t()]}
  @type capture_shapes :: %{optional(atom()) => MapSet.t(atom())}

  @callback handle_rule(rule :: atom(), captures :: captures(), context :: context()) ::
              {:ok, term(), context()} | {:error, Error.t()}

  @callback handle_token(token :: atom(), text :: String.t(), context :: context()) ::
              {:ok, term()} | {:error, Error.t()}

  @callback finalize(context :: context()) :: :ok | {:error, [Error.t()]}

  @optional_callbacks handle_rule: 3, handle_token: 3, finalize: 1

  @doc """
  Eagerly invokes every capture's `eval`, in order, threading `context`
  through -- the plain bottom-up fold that's correct for grammars with no
  special-form semantics (most config/markup/query grammars, as opposed
  to something like LISP's `if`/`quote`, which need to *not* evaluate an
  untaken branch at all). A list-valued capture (the same name captured
  more than once, e.g. inside a `*`) resolves to a list of values in the
  same order. Halts and returns immediately on the first error.
  """
  @spec eval_all(captures(), context()) ::
          {:ok, %{optional(atom()) => term()}, context()} | {:error, Error.t()}
  def eval_all(captures, context) do
    Enum.reduce_while(captures, {:ok, %{}, context}, fn {name, cap_or_list}, {:ok, acc, ctx} ->
      case eval_one(cap_or_list, ctx) do
        {:ok, value, ctx} -> {:cont, {:ok, Map.put(acc, name, value), ctx}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp eval_one(caps, ctx) when is_list(caps) do
    result =
      Enum.reduce_while(caps, {:ok, [], ctx}, fn cap, {:ok, acc, ctx} ->
        case cap.eval.(ctx) do
          {:ok, value, ctx} -> {:cont, {:ok, [value | acc], ctx}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, acc, ctx} -> {:ok, Enum.reverse(acc), ctx}
      {:error, _} = err -> err
    end
  end

  defp eval_one(%Capture{} = cap, ctx), do: cap.eval.(ctx)

  @doc """
  The single entry point tying `Grammar.VM`'s raw capture tree to a
  grammar's Actions module: evaluates the root rule, then runs
  `finalize/1` over whatever context that produced. Returns the final
  context alongside the value -- needed whenever more than one top-level
  match must thread context forward (e.g. loading a multi-form source
  file one top-level form at a time); callers that only need the value
  can just ignore it.

  `capture_shapes` (from `Grammar.VM.RuleCompiler.capture_shapes/1`) says,
  per rule, which capture names sit under a `*`/`+`/`{n,m}` -- needed so
  e.g. an `op:` that matched zero times still shows up as `[]`, not as a
  missing key indistinguishable from "this rule shape never has an
  `:op`" (see that function's docs for why this can't just be inferred
  from the raw tree at dispatch time).
  """
  @spec evaluate(atom(), map(), module(), context(), capture_shapes()) ::
          {:ok, term(), context()} | {:error, Error.t() | [Error.t()]}
  def evaluate(root_rule, raw_captures, actions_module, initial_context, capture_shapes \\ %{}) do
    # `function_exported?/3` only answers correctly for a module that has
    # actually been loaded into this BEAM instance -- true for every
    # module reached through a normal call chain, but not guaranteed for
    # one only ever referenced dynamically (e.g. passed in as this very
    # argument), so make sure of it before relying on the check anywhere
    # below.
    Code.ensure_loaded(actions_module)

    with {:ok, value, context} <-
           dispatch_rule(actions_module, root_rule, raw_captures, initial_context, capture_shapes) do
      case run_finalize(actions_module, context) do
        :ok -> {:ok, value, context}
        {:error, _} = err -> err
      end
    end
  end

  defp run_finalize(actions_module, context) do
    if function_exported?(actions_module, :finalize, 1) do
      actions_module.finalize(context)
    else
      :ok
    end
  end

  # ---- dispatch + default fallback ---------------------------------------

  @doc false
  def dispatch_rule(actions_module, rule_name, raw_captures, context, capture_shapes) do
    normalized =
      normalize_repeatables(raw_captures, Map.get(capture_shapes, rule_name, MapSet.new()))

    captures = build_captures(actions_module, normalized, capture_shapes)

    if function_exported?(actions_module, :handle_rule, 3) do
      call_with_fallback(
        fn -> actions_module.handle_rule(rule_name, captures, context) end,
        {actions_module, :handle_rule, 3},
        fn -> default_handle_rule(rule_name, captures, context) end
      )
    else
      default_handle_rule(rule_name, captures, context)
    end
  end

  @doc false
  def dispatch_token(actions_module, token_name, text, context) do
    if function_exported?(actions_module, :handle_token, 3) do
      call_with_fallback(
        fn -> actions_module.handle_token(token_name, text, context) end,
        {actions_module, :handle_token, 3},
        fn -> {:ok, text} end
      )
    else
      {:ok, text}
    end
  end

  # "A grammar's Actions module only implements the rules/tokens it needs
  # custom behavior for" means *per rule/token name*, not just per
  # callback -- a calculator's Actions module might implement handle_rule
  # for :expr/:term but not :factor, expecting :factor to fall through to
  # the default. `function_exported?/3` can only tell us the callback
  # exists at all, not whether THIS call has a matching clause, so the
  # fallback has to happen here, at the call site -- checked against the
  # exact module/function/arity so an unrelated `FunctionClauseError`
  # raised from somewhere *inside* a real clause's own logic isn't
  # swallowed.
  defp call_with_fallback(fun, {mod, name, arity}, fallback) do
    fun.()
  rescue
    e in FunctionClauseError ->
      if e.module == mod and e.function == name and e.arity == arity do
        fallback.()
      else
        reraise e, __STACKTRACE__
      end
  end

  defp normalize_repeatables(raw_captures, repeatable_names) do
    Enum.reduce(repeatable_names, raw_captures, fn name, acc ->
      Map.update(acc, name, [], &List.wrap/1)
    end)
  end

  # Exactly one capture, captured only once (not via repetition): pass its
  # value straight through, unwrapped -- e.g. calculator's
  # `factor := NUMBER | "(" expr ")"` never needs its own %Ichor.Node{},
  # its single capture's value already *is* factor's value.
  defp default_handle_rule(rule_name, captures, context) when map_size(captures) == 1 do
    case Map.to_list(captures) do
      [{_name, %Capture{} = cap}] -> cap.eval.(context)
      [{_name, list}] when is_list(list) -> build_node(rule_name, captures, context)
    end
  end

  defp default_handle_rule(rule_name, captures, context),
    do: build_node(rule_name, captures, context)

  defp build_node(rule_name, captures, context) do
    with {:ok, resolved, context} <- eval_all(captures, context) do
      {:ok, %Node{rule: rule_name, captures: resolved, span: nil}, context}
    end
  end

  defp build_captures(actions_module, raw_captures, capture_shapes) do
    Map.new(raw_captures, fn {name, raw} ->
      {name, build_capture(actions_module, raw, capture_shapes)}
    end)
  end

  defp build_capture(actions_module, raw, capture_shapes) when is_list(raw) do
    Enum.map(raw, &build_capture(actions_module, &1, capture_shapes))
  end

  defp build_capture(actions_module, {:token, name, text} = node, _capture_shapes) do
    %Capture{
      node: node,
      eval: fn ctx ->
        with {:ok, value} <- dispatch_token(actions_module, name, text, ctx) do
          {:ok, value, ctx}
        end
      end
    }
  end

  defp build_capture(actions_module, {:rule, name, raw_sub_captures} = node, capture_shapes) do
    %Capture{
      node: node,
      eval: fn ctx ->
        dispatch_rule(actions_module, name, raw_sub_captures, ctx, capture_shapes)
      end
    }
  end

  defp build_capture(_actions_module, {:text, text} = node, _capture_shapes) do
    %Capture{node: node, eval: fn ctx -> {:ok, text, ctx} end}
  end
end
