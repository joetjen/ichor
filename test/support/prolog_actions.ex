defmodule Prolog.Actions do
  @moduledoc """
  Turns the raw capture tree `test/prolog/prolog.aether` builds into
  `Prolog.Terms`-shaped data (`test/support/prolog.ex`, Track 6's own
  worked example) -- `{:compound, functor, args}`, plain Elixir atoms
  for ground atoms, `{:var, ref}` for variables. Closes the loop between
  Track 1 (this grammar, real syntax) and Track 6 (`Ichor.Backtrack`,
  already proven against hand-built terms): a fact parsed here unifies
  directly against a hand-built query term via the exact same
  `Ichor.Backtrack.Bindings`/`Prolog.Terms` substrate.

  Variable names are scoped to one clause in real Prolog -- two clauses
  both using `X` never share a variable, but every `X` *within* one
  clause (spanning its head and its whole body) must. `freshen/1` gets
  this right via `Ichor.Toolkit.TermWalk`: `fold/4` first discovers
  every distinct variable *name* used in the clause, then `rewrite/3`
  replaces each occurrence using one fixed name-to-fresh-ref map --
  exactly the "fold to discover, then rewrite from a precomputed map"
  shape `Ichor.Toolkit.TypeScheme.generalize/4`/`instantiate/3` already
  use together for the same reason (a quantified type variable can't be
  freshened consistently without first knowing the full set of them).
  """

  @behaviour Ichor.Actions

  alias Ichor.Toolkit.{Pratt, TermWalk}
  alias Prolog.Terms

  @doc "A fresh context, seeded with the default Prolog operator table."
  @spec new_context() :: %{operators: Pratt.table()}
  def new_context, do: %{operators: default_operators()}

  # ISO Prolog's own `op/3` convention is "bigger number binds looser"
  # (1200, `:-`'s own priority, is the loosest of all); `Ichor.Toolkit.Pratt`'s
  # is the opposite ("bigger number binds tighter", e.g. Calculator's `*`
  # above `+`). `iso_to_pratt/1` is the one place that mismatch gets
  # translated, so every other line in this module uses real ISO Prolog
  # priority numbers directly -- 700 for `is`, 500 for `+`/`-`, 400 for
  # `*`/`/`, 200 for prefix `-` -- exactly as a real `op/3` directive would.
  defp iso_to_pratt(iso_prec), do: 1200 - iso_prec

  defp default_operators do
    Pratt.new()
    |> Pratt.prefix("-", iso_to_pratt(200))
    |> Pratt.infix("+", iso_to_pratt(500))
    |> Pratt.infix("-", iso_to_pratt(500))
    |> Pratt.infix("*", iso_to_pratt(400))
    |> Pratt.infix("/", iso_to_pratt(400))
    |> Pratt.infix("is", iso_to_pratt(700))
    |> Pratt.infix("=", iso_to_pratt(700))
    |> Pratt.infix("<", iso_to_pratt(700))
    |> Pratt.infix(">", iso_to_pratt(700))
  end

  @impl true
  def handle_token(:NUMBER, text, _ctx), do: {:ok, String.to_integer(text)}
  def handle_token(:VAR, text, _ctx), do: {:ok, {:var_ref, text}}
  def handle_token(:ATOM, text, _ctx), do: {:ok, String.to_atom(text)}
  def handle_token(:OP, text, _ctx), do: {:ok, String.to_atom(text)}

  @impl true
  # `clause := (directive | rule | fact) DOT` captures two things (the
  # matched alternative *and* the literal `DOT`), so the default
  # single-capture passthrough doesn't apply -- unlike `fact :=
  # compound_or_atom`/`primary := ... | LPAREN inner:term RPAREN`, which
  # each capture exactly one thing and need no clause here at all.
  def handle_rule(:clause, captures, ctx) do
    cap = Map.get(captures, :fact) || Map.get(captures, :rule) || Map.get(captures, :directive)
    cap.eval.(ctx)
  end

  def handle_rule(:compound, %{functor: functor_cap, args: args_cap}, ctx) do
    with {:ok, functor, ctx} <- functor_cap.eval.(ctx),
         {:ok, args, ctx} <- eval_list(:args, args_cap, ctx) do
      {:ok, {:compound, functor, args}, ctx}
    end
  end

  def handle_rule(:arglist, %{term: term_caps}, ctx), do: eval_list(:term, term_caps, ctx)
  def handle_rule(:conjunction, %{term: term_caps}, ctx), do: eval_list(:term, term_caps, ctx)

  def handle_rule(:fact, %{compound_or_atom: cap}, ctx) do
    with {:ok, term, ctx} <- cap.eval.(ctx) do
      {:ok, freshen(term), ctx}
    end
  end

  def handle_rule(:rule, %{head: head_cap, body: body_cap}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, body, ctx} <- body_cap.eval.(ctx) do
      [fresh_head | fresh_body] = freshen_all([head | body])
      {:ok, {:rule, fresh_head, fresh_body}, ctx}
    end
  end

  def handle_rule(:directive, %{goal: goal_cap}, ctx) do
    with {:ok, goal, ctx} <- goal_cap.eval.(ctx) do
      goal = freshen(goal)
      {:ok, {:directive, goal}, apply_directive(goal, ctx)}
    end
  end

  defp apply_directive({:compound, :op, [prec, type, name]}, ctx) do
    op_name = Atom.to_string(name)
    pratt_prec = iso_to_pratt(prec)

    table =
      case type do
        t when t in [:fy, :fx] -> Pratt.prefix(ctx.operators, op_name, pratt_prec)
        t when t in [:xf, :yf] -> Pratt.postfix(ctx.operators, op_name, pratt_prec)
        :xfy -> Pratt.infix(ctx.operators, op_name, pratt_prec, :right)
        t when t in [:xfx, :yfx] -> Pratt.infix(ctx.operators, op_name, pratt_prec, :left)
      end

    %{ctx | operators: table}
  end

  defp apply_directive(_goal, ctx), do: ctx

  defp eval_list(key, caps, ctx) do
    with {:ok, wrapped, ctx} <- Ichor.Actions.eval_all(%{key => caps}, ctx) do
      {:ok, Map.fetch!(wrapped, key), ctx}
    end
  end

  defp freshen(term), do: term |> List.wrap() |> freshen_all() |> hd()

  defp freshen_all(terms) do
    wrapped = {:compound, :"$group", terms}

    names =
      TermWalk.fold(Terms, wrapped, MapSet.new(), fn
        {:var_ref, name}, acc -> MapSet.put(acc, name)
        _other, acc -> acc
      end)

    refs = Map.new(names, fn name -> {name, {:var, make_ref()}} end)

    {:compound, :"$group", freshened} =
      TermWalk.rewrite(Terms, wrapped, fn
        {:var_ref, name} -> Map.fetch!(refs, name)
        other -> other
      end)

    freshened
  end
end
