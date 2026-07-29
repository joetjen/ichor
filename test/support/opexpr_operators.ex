defmodule OpExprTest.Operators do
  @moduledoc """
  Toy stand-in for Prolog's `op/3`: precedence-climbs a chain of
  `primary (OP primary)*` where each `OP`'s precedence/associativity is
  looked up in a table living in `context` (mutable across top-level
  forms via `run_sequence`/`Ichor.Actions.evaluate`, exactly like a
  Prolog clause database would be) rather than being fixed in the
  grammar itself -- via `Ichor.Toolkit.Pratt`, whose own moduledoc cites
  this exact function as the pattern it was extracted from (this fixture
  only ever needed infix chains, so only `callbacks.build`'s `:infix`
  clause is implemented).

  A `@native(...)` node is opaque to Aether's own `@skip` splicing --
  that only ever gets woven into ordinary `Seq` nodes, and this rule has
  none -- so this has to skip whitespace between tokens itself, same as
  any hand-written scanner would.
  """

  alias Grammar.VM.Token
  alias Ichor.Toolkit.Pratt

  # Named `parse_infix`, not `match` -- `@native(...)` names its own
  # callback function explicitly (that's the point: a grammar can route
  # to any function shaped like `Ichor.CustomRule.match/4`, not just one
  # literally named `match`), so there's nothing to `@impl` against here.
  def parse_infix(stream, pos, context, %{primary: primary}) do
    callbacks = %{
      peek_op: fn pos -> operator_at(stream, skip_space(stream, pos)) end,
      parse_primary: fn pos -> primary.(stream, skip_space(stream, pos)) end,
      build: fn :infix, op_name, [left, right] ->
        {:rule, :expr, %{op: {:token, :OP, op_name}, left: left, right: right}}
      end
    }

    Pratt.parse(Enum.into(context.operators, Pratt.new(), &to_infix_entry/1), pos, callbacks)
  end

  defp to_infix_entry({op_name, {prec, assoc}}), do: {op_name, %{infix: {prec, assoc}}}

  defp operator_at(stream, pos) do
    with true <- pos < tuple_size(stream),
         %Token{name: :OP, text: name} <- elem(stream, pos) do
      {name, pos + 1}
    else
      _ -> nil
    end
  end

  defp skip_space(stream, pos) do
    case pos < tuple_size(stream) && elem(stream, pos) do
      %Token{name: :SPACE} -> skip_space(stream, pos + 1)
      _ -> pos
    end
  end
end
