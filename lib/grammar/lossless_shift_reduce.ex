defmodule Grammar.LosslessShiftReduce do
  @moduledoc """
  The lossless match of the interpreted shift-reduce backends,
  `Grammar.LR` and `Grammar.GLR` (`design/lossless-mode.md`): tokenize,
  run the table with the rules recording, place an error against the
  input, weave the tree.

  The two differ only in the run -- `Grammar.LR.Lossless.run/6`, or
  `Grammar.GLR.Runtime.run/7` building with
  `Ichor.Syntax.Record.reduced/3` -- so it is handed in, and the
  surrounding steps are each backend's ordinary ones, in the same order:
  the lossless parse fails exactly where and how the ordinary one does.
  """

  alias Grammar.LRTable
  alias Ichor.{Actions, Error, Syntax}
  alias Ichor.Syntax.Record

  @typedoc "A run over a table, as `Grammar.LR.Lossless.run/6` takes its arguments."
  @type run ::
          (Grammar.GLR.Runtime.action_fn(),
           Grammar.GLR.Runtime.goto_fn(),
           %{non_neg_integer() => LRTable.Production.t()},
           LRTable.state_id(),
           atom(),
           tuple() ->
             {:ok, non_neg_integer(), Ichor.Capture.raw_captures()} | {:error, Error.t()})

  @doc """
  The lossless tree of `input` under `grammar`, whose table is `table`,
  and the ordinary captures beside it with the locator of their recorded
  positions, for `evaluated/5`.
  """
  @spec matched(Aether.Grammar.t(), LRTable.t(), String.t(), term(), run()) ::
          {:ok, Syntax.Node.t(), Ichor.Capture.raw_captures(), Grammar.Source.Locator.t()}
          | {:error, Error.t()}
  def matched(grammar, table, input, context, run) do
    with {:ok, tokens} <- Grammar.VM.tokenize(grammar, input, context) do
      stream = tokens |> Grammar.Source.trimmed(grammar.skip) |> List.to_tuple()
      action_fn = fn state, term -> table.action |> Map.get(state, %{}) |> Map.get(term, []) end
      goto_fn = fn state, nonterm -> table.goto |> Map.get(state, %{}) |> Map.get(nonterm) end

      case run.(
             action_fn,
             goto_fn,
             table.productions,
             table.start_state,
             table.end_symbol,
             stream
           ) do
        {:error, error} ->
          {:error, Grammar.Source.placed(error, input)}

        {:ok, pos, raw_captures} ->
          {raw_captures, record} = Record.root(grammar.root, pos, raw_captures)
          locator = Grammar.Source.Locator.new(stream, input)
          {:ok, Syntax.tree(record, tokens, grammar.skip), raw_captures, locator}
      end
    end
  end

  @doc "`{:ok, value, tree}` from a `matched/5` result, `value` evaluated as the backend's `run/4` evaluates it."
  @spec evaluated(
          {:ok, Syntax.Node.t(), Ichor.Capture.raw_captures(), Grammar.Source.Locator.t()}
          | {:error, term()},
          Aether.Grammar.t(),
          module(),
          Actions.context(),
          Actions.capture_shapes()
        ) :: {:ok, term(), Syntax.Node.t()} | {:error, term()}
  def evaluated(matched, grammar, actions_module, initial_context, capture_shapes) do
    with {:ok, tree, raw_captures, locator} <- matched,
         {:ok, value, _context} <-
           Actions.evaluate(
             grammar.root,
             raw_captures,
             actions_module,
             initial_context,
             capture_shapes,
             locator: locator
           ) do
      {:ok, value, tree}
    end
  end
end
