defmodule Prolog.Grammar do
  @moduledoc """
  Track 1's real motivating example, for real: Prolog's own `op/3`,
  against genuine Prolog syntax (`test/prolog/prolog.aether`) instead of
  `test/opexpr/opexpr.aether`'s toy stand-in. Drives `Ichor.Toolkit.Pratt`
  entirely off `context.operators` (a `Pratt` table), which
  `Prolog.Actions`' own directive handling extends at runtime as real
  `:- op(Prec, Type, Name).` clauses are processed via
  `Grammar.VM.run_sequence/4`'s per-form context threading.

  A `@native(...)` node is opaque to Aether's own `@skip` splicing, so
  -- like `test/support/opexpr_operators.ex` -- this has to skip
  whitespace between tokens itself.

  Builds every application (prefix, infix, *and* explicit `f(...)` call
  syntax) into the same `{:rule, :compound, %{functor: ..., args: ...}}`
  raw capture shape `Prolog.Actions.handle_rule(:compound, ...)` already
  handles -- real Prolog's own fact that `a + b` is just sugar for
  `+(a, b)`, not a separate kind of term.
  """

  alias Grammar.VM.Token
  alias Ichor.Toolkit.Pratt

  def parse_term(stream, pos, context, %{primary: primary}) do
    callbacks = %{
      peek_op: fn pos -> operator_at(stream, pos, context.operators) end,
      parse_primary: fn pos -> primary.(stream, skip_ws(stream, pos)) end,
      build: fn
        :prefix, op, [arg] -> {:rule, :compound, %{functor: {:token, :OP, op}, args: [arg]}}
        :infix, op, [l, r] -> {:rule, :compound, %{functor: {:token, :OP, op}, args: [l, r]}}
      end
    }

    Pratt.parse(context.operators, pos, callbacks)
  end

  defp operator_at(stream, pos, table) do
    pos = skip_ws(stream, pos)

    with true <- pos < tuple_size(stream),
         %Token{name: name, text: text} <- elem(stream, pos),
         true <- name in [:OP, :ATOM],
         true <- Map.has_key?(table, text) do
      {text, pos + 1}
    else
      _ -> nil
    end
  end

  defp skip_ws(stream, pos) do
    case pos < tuple_size(stream) && elem(stream, pos) do
      %Token{name: :WS} -> skip_ws(stream, pos + 1)
      _ -> pos
    end
  end
end
