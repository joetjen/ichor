defmodule Lisp.Actions do
  @moduledoc """
  A worked example: proof that `Ichor.Actions`'s thunk model supports
  selective/deferred evaluation (`quote`, `cond`'s untaken branch) and
  macro expansion, not just the eager fold `Calculator.Actions` needed.

  Scoped to `if`/`quote`/`fn`/`let`/`def` behaving correctly, and an
  untaken `if` branch not hanging -- not a production Lisp. Concretely,
  that means:

    - All 6 core special forms are implemented (`quote`, `fn`, `def`,
      `cond`, `defmacro`) except `require`: loading `stdlib.lisp` is done
      directly in Elixir (`Lisp.Stdlib`), so the grammar never needs a
      `require` *form* here.
    - `if`/`let` are stdlib macros, built from `cond`/`fn`.
      `unless`/`case`/`defn`/`defp` are *not* implemented -- they're
      outside this fragment's scope, `defp`/`case` specifically need
      metadata/rest-param machinery this file deliberately skips, and
      adding them "for completeness" would be scope creep: a gap is fine
      as long as the features a fixture exists to demonstrate are fully
      correct.
    - `quasiquote`/`unquote`/`unquote-splice` reify (reader-level sugar)
      but have no special *evaluation* semantics of their own beyond
      behaving like `quote` -- true quasiquote expansion (walking a
      template for nested unquotes) is real additional machinery this
      fragment doesn't need.
    - No metadata (`with-meta`/`^`) and no macro hygiene (an accepted
      gap, not a bug).
  """

  @behaviour Ichor.Actions

  alias Lisp.{Closure, Keyword, Macro, Symbol, Vector}

  # ---- context: a lexical env (discarded across a function call, like
  # any real lexical scope) plus a macro table (global/persistent, since
  # `defmacro` in real Lisps has always meant "everywhere from now on",
  # not "only in this scope") ------------------------------------------

  @type context :: %{env: %{String.t() => term()}, macros: %{String.t() => Macro.t()}}

  @doc "An empty context -- the starting point for the three-layer bootstrap, before `Lisp.Primitives.seed/1` or `Lisp.Stdlib.load/1`."
  @spec new_context() :: context()
  def new_context, do: %{env: %{}, macros: %{}}

  # ---- token evaluation ---------------------------------------------------
  # Bare symbols are variable lookups (the dispatch below already
  # handles a symbol used as `list`'s own head specially, without ever
  # evaluating it as one of these -- see `symbol_name/1`). Keywords,
  # strings, and numbers are self-evaluating.

  @impl true
  def handle_token(:SYMBOL, text, ctx) do
    case Map.get(ctx.env, text, :__unbound__) do
      :__unbound__ ->
        {:error, Ichor.Error.new(message: "unbound symbol: #{text}", stage: :action)}

      value ->
        {:ok, value}
    end
  end

  def handle_token(:KEYWORD, ":" <> name, _ctx), do: {:ok, %Keyword{name: name}}
  def handle_token(:STRING, text, _ctx), do: {:ok, decode_string(text)}
  def handle_token(:NUMBER, text, _ctx), do: {:ok, decode_number(text)}

  # ---- rule evaluation -----------------------------------------------------
  # `form`/`atom` need no clause here at all: each alternative has exactly
  # one capture, so the default fallback already passes the
  # matched child's value straight through.

  @impl true
  def handle_rule(:list, %{form: []}, ctx), do: {:ok, [], ctx}

  def handle_rule(:list, %{form: [head | rest]}, ctx) do
    case symbol_name(head.node) do
      "quote" ->
        [arg] = rest
        {:ok, reify(arg.node), ctx}

      "fn" ->
        [params_cap, body_cap] = rest
        params = param_list(reify(params_cap.node))
        {:ok, %Closure{params: params, body_eval: body_cap.eval, captured_ctx: ctx}, ctx}

      "def" ->
        eval_def(rest, ctx)

      "cond" ->
        eval_cond(rest, ctx)

      "defmacro" ->
        eval_defmacro(rest, ctx)

      name when is_binary(name) ->
        case Map.fetch(ctx.macros, name) do
          {:ok, macro} -> expand_and_eval(macro, rest, ctx)
          :error -> eval_application(head, rest, ctx)
        end

      nil ->
        eval_application(head, rest, ctx)
    end
  end

  def handle_rule(:vector, %{form: forms}, ctx) do
    with {:ok, items, ctx} <- eval_forms(forms, ctx) do
      {:ok, %Vector{items: items}, ctx}
    end
  end

  def handle_rule(:map, %{form: forms}, ctx) do
    with {:ok, flat, ctx} <- eval_forms(forms, ctx) do
      pairs = flat |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)
      {:ok, %Lisp.Map{pairs: pairs}, ctx}
    end
  end

  # `'x` / `` `x `` / `~x` / `~@x`: reify without evaluating. Quasiquote
  # and the two unquote forms behave like plain `quote` here (see the
  # module docs' scope note) -- real template-expansion semantics aren't
  # needed to show the thunk model works.
  def handle_rule(:quote_sugar, %{form: f}, ctx), do: {:ok, reify(f.node), ctx}
  def handle_rule(:quasiquote_sugar, %{form: f}, ctx), do: {:ok, reify(f.node), ctx}
  def handle_rule(:unquote_sugar, %{form: f}, ctx), do: {:ok, reify(f.node), ctx}
  def handle_rule(:unquote_splice_sugar, %{form: f}, ctx), do: {:ok, reify(f.node), ctx}

  # ---- special forms -------------------------------------------------------

  defp eval_def([name_cap, value_cap], ctx) do
    name = symbol_name(name_cap.node)

    with {:ok, value, ctx} <- value_cap.eval.(ctx) do
      {:ok, %Symbol{name: name}, %{ctx | env: Map.put(ctx.env, name, value)}}
    end
  end

  defp eval_cond([], ctx), do: {:ok, nil, ctx}

  defp eval_cond([test_cap, expr_cap | more], ctx) do
    with {:ok, test_val, ctx} <- test_cap.eval.(ctx) do
      # only the matching pair's expr ever evaluates -- an untaken branch
      # (including one that would side-effect or never terminate) simply
      # never runs -- the whole reason this can't be a plain
      # eager fold.
      if truthy?(test_val), do: expr_cap.eval.(ctx), else: eval_cond(more, ctx)
    end
  end

  defp eval_defmacro([name_cap, params_cap, body_cap], ctx) do
    name = symbol_name(name_cap.node)
    params = param_list(reify(params_cap.node))
    macro = %Macro{params: params, body_node: body_cap.node}
    {:ok, %Symbol{name: name}, %{ctx | macros: Map.put(ctx.macros, name, macro)}}
  end

  # A param list is conventionally written `[x y]` (a vector, e.g. `fn`)
  # or `(x y)` (a plain list, e.g. `defmacro`'s own
  # `(defmacro if (test then else) ...)`); accepted either way.
  defp param_list(%Vector{items: items}), do: items
  defp param_list(list) when is_list(list), do: list

  # Two evaluation passes: the first, in the *macro's own*
  # param bindings, produces the expansion; the second re-enters
  # evaluation on that expansion in the *caller's* context -- textual
  # substitution, not a closure over the macro's definition site. Only the
  # macro table survives back out to the caller (defmacro is global, like
  # any real Lisp's); the caller's own lexical env is untouched.
  defp expand_and_eval(%Macro{params: params, body_node: body_node}, arg_caps, ctx) do
    arg_values = Enum.map(arg_caps, &reify(&1.node))
    expansion_ctx = bind_params(params, arg_values, ctx)

    with {:ok, expansion, expanded_ctx} <-
           Ichor.Actions.evaluate_node(body_node, __MODULE__, expansion_ctx),
         {:ok, result, final_ctx} <-
           Ichor.Actions.evaluate_node(unreify(expansion), __MODULE__, ctx) do
      {:ok, result, %{final_ctx | macros: expanded_ctx.macros}}
    end
  end

  defp eval_application(head, arg_caps, ctx) do
    with {:ok, fun, ctx} <- head.eval.(ctx),
         {:ok, args, ctx} <- eval_all_caps(arg_caps, ctx) do
      apply_lisp(fun, args, ctx)
    end
  end

  defp apply_lisp(fun, args, ctx) when is_function(fun) do
    {:ok, apply(fun, [args]), ctx}
  end

  defp apply_lisp(
         %Closure{params: params, body_eval: body_eval, captured_ctx: captured_ctx},
         args,
         ctx
       ) do
    call_ctx = bind_params(params, args, captured_ctx)

    with {:ok, result, called_ctx} <- body_eval.(call_ctx) do
      # discard the call's own local env, but keep any global macro
      # definitions it introduced -- ordinary lexical scoping for
      # variables, global persistence for macros (see expand_and_eval).
      {:ok, result, %{ctx | macros: called_ctx.macros}}
    end
  end

  defp bind_params(params, args, ctx) do
    bindings = params |> Enum.map(& &1.name) |> Enum.zip(args) |> Map.new()
    %{ctx | env: Map.merge(ctx.env, bindings)}
  end

  defp eval_forms(caps, ctx), do: eval_all_caps(caps, ctx)

  defp eval_all_caps(caps, ctx) do
    result =
      Enum.reduce_while(caps, {:ok, [], ctx}, fn cap, {:ok, acc, ctx} ->
        case cap.eval.(ctx) do
          {:ok, val, ctx} -> {:cont, {:ok, [val | acc], ctx}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, acc, ctx} -> {:ok, Enum.reverse(acc), ctx}
      {:error, _} = err -> err
    end
  end

  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true

  # ---- symbol_name/1: raw text of a leaf, without evaluating it -----------
  # Used purely to decide dispatch, so it doesn't matter that a
  # non-symbol leaf (a number, say) also produces "some text": the
  # dispatch above only treats it specially if it happens to equal one of
  # the 6 special-form names or a live macro name, and falls through to
  # ordinary application otherwise, same as any real Lisp's reader does.

  @spec symbol_name(Ichor.Capture.node_t()) :: String.t() | nil
  def symbol_name(raw) do
    case unwrap(raw) do
      {:token, :SYMBOL, text} -> text
      _ -> nil
    end
  end

  # ---- reify/1 (raw node -> Lisp value) and unreify/1 (Lisp value -> raw
  # node) -- code as the grammar's own data, not Ichor's
  # internal capture-tree shape. `unwrap/1` transparently collapses the
  # grammar's own "one capture, pass straight through" rules (`form`,
  # `atom`, `reader_macro`) so reify only has to handle the genuinely
  # distinct shapes (a leaf token, or a compound rule like `list`).

  @spec reify(Ichor.Capture.node_t()) :: term()
  def reify(raw) do
    case unwrap(raw) do
      {:token, :SYMBOL, text} ->
        %Symbol{name: text}

      {:token, :KEYWORD, ":" <> name} ->
        %Keyword{name: name}

      {:token, :STRING, text} ->
        decode_string(text)

      {:token, :NUMBER, text} ->
        decode_number(text)

      # `form`'s absent entirely (not even `[]`) when a repeated capture
      # matched zero times, since this reads `.node` directly rather than
      # going through `dispatch_rule`'s own normalization (the same
      # "missing key vs. empty list" ambiguity as `handle_rule`'s own
      # captures map, just here for reify instead). `captures` is a raw
      # `Ichor.Capture.raw_captures/0` ordered list here, not the
      # evaluated map `handle_rule/3` gets -- `Keyword.get/3` reads it the
      # same way `Map.get/3` used to.
      {:rule, :list, captures} ->
        Elixir.Keyword.get(captures, :form, [])
        |> List.wrap()
        |> Enum.map(&reify_capture_or_node/1)

      {:rule, :vector, captures} ->
        forms =
          Elixir.Keyword.get(captures, :form, [])
          |> List.wrap()
          |> Enum.map(&reify_capture_or_node/1)

        %Vector{items: forms}

      {:rule, :map, captures} ->
        pairs =
          captures
          |> Elixir.Keyword.get(:form, [])
          |> List.wrap()
          |> Enum.map(&reify_capture_or_node/1)
          |> Enum.chunk_every(2)
          |> Map.new(fn [k, v] -> {k, v} end)

        %Lisp.Map{pairs: pairs}

      {:rule, :quote_sugar, captures} ->
        [%Symbol{name: "quote"}, reify_capture_or_node(Elixir.Keyword.fetch!(captures, :form))]

      {:rule, :quasiquote_sugar, captures} ->
        [
          %Symbol{name: "quasiquote"},
          reify_capture_or_node(Elixir.Keyword.fetch!(captures, :form))
        ]

      {:rule, :unquote_sugar, captures} ->
        [%Symbol{name: "unquote"}, reify_capture_or_node(Elixir.Keyword.fetch!(captures, :form))]

      {:rule, :unquote_splice_sugar, captures} ->
        [
          %Symbol{name: "unquote-splice"},
          reify_capture_or_node(Elixir.Keyword.fetch!(captures, :form))
        ]

      {:text, text} ->
        text
    end
  end

  defp reify_capture_or_node(%Ichor.Capture{node: node}), do: reify(node)
  defp reify_capture_or_node(raw), do: reify(raw)

  @spec unreify(term()) :: Ichor.Capture.node_t()
  def unreify(%Symbol{name: name}), do: {:token, :SYMBOL, name}
  def unreify(%Keyword{name: name}), do: {:token, :KEYWORD, ":" <> name}
  def unreify(list) when is_list(list), do: {:rule, :list, [form: Enum.map(list, &unreify/1)]}
  def unreify(%Vector{items: items}), do: {:rule, :vector, [form: Enum.map(items, &unreify/1)]}

  def unreify(%Lisp.Map{pairs: pairs}) do
    forms = Enum.flat_map(pairs, fn {k, v} -> [unreify(k), unreify(v)] end)
    {:rule, :map, [form: forms]}
  end

  def unreify(n) when is_integer(n), do: {:token, :NUMBER, Integer.to_string(n)}
  def unreify(n) when is_float(n), do: {:token, :NUMBER, Float.to_string(n)}
  def unreify(nil), do: {:token, :SYMBOL, "nil"}
  def unreify(s) when is_binary(s), do: {:token, :STRING, "\"" <> s <> "\""}

  # Transparently collapses "exactly one capture" wrapper rules (`form`,
  # `atom`, `reader_macro`) down to the leaf or genuinely-compound node
  # underneath -- e.g. a `form` capture that matched `quote`'s SYMBOL ends
  # up, after unwrapping through `form` then `atom`, as plain
  # `{:token, :SYMBOL, "quote"}`.
  defp unwrap({:rule, _name, captures} = raw) do
    case captures do
      [{_key, %Ichor.Capture{node: single}}] -> unwrap(single)
      [{_key, single}] when not is_list(single) -> unwrap(single)
      _ -> raw
    end
  end

  defp unwrap(other), do: other

  defp decode_string(text) do
    text
    |> String.slice(1..-2//1)
    |> String.replace("\\\"", "\"")
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\\", "\\")
  end

  defp decode_number(text) do
    if String.contains?(text, "."), do: String.to_float(text), else: String.to_integer(text)
  end
end
