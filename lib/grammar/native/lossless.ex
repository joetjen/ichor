defmodule Grammar.Native.Lossless do
  @moduledoc """
  What `lossless: true` adds to a generated LR or GLR parser
  (`design/lossless-mode.md`): `parse_lossless/1,2` and
  `run_lossless/1,2`, over a shift-reduce run that records the rules
  (`Grammar.LR.Lossless`, or `Grammar.GLR.Runtime.run/7` building with
  `Ichor.Syntax.Record.reduced/3`).

  The two engines differ only in that run, so it is handed in as quoted
  code; the rest -- trimming, placing an error against the input,
  weaving the tree, evaluating the value -- is one definition for both,
  and the same as each engine's ordinary `parse/2` and `run/2` do.
  """

  alias Grammar.LRTable

  @doc """
  The generated functions. `run` is quoted code evaluating, with
  `stream_var/0` bound to the trimmed token tuple, to `{:ok, pos,
  raw_captures}` with the records inside, or `{:error, error}`.
  """
  @spec shift_reduce_defs(Aether.Grammar.t(), module(), Macro.t()) :: Macro.t()
  def shift_reduce_defs(grammar, actions_module, run) do
    root = grammar.root
    skip = grammar.skip
    stream = stream_var()

    capture_shapes =
      Ichor.Toolkit.Codegen.capture_shapes_ast(Grammar.VM.RuleCompiler.capture_shapes(grammar))

    quote do
      @doc "Like `parse/2`, but returns the lossless tree of `input` (`Ichor.Syntax`): every byte of it, trivia and punctuation included, under every rule that matched. Fails exactly as `parse/2` fails."
      @spec parse_lossless(String.t(), term()) ::
              {:ok, Ichor.Syntax.Node.t()} | {:error, Ichor.Error.t()}
      def parse_lossless(input, context \\ nil) do
        with {:ok, tree, _raw_captures, _locator} <- lossless_match(input, context) do
          {:ok, tree}
        end
      end

      @doc "Like `run/2`, returning the lossless tree of `input` beside the value: `{:ok, value, tree}`, `value` being exactly what `run/2` returns."
      @spec run_lossless(String.t(), Ichor.Actions.context()) ::
              {:ok, term(), Ichor.Syntax.Node.t()}
              | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
      def run_lossless(input, initial_context \\ nil) do
        with {:ok, tree, raw_captures, locator} <- lossless_match(input, initial_context),
             {:ok, value, _context} <-
               Ichor.Actions.evaluate(
                 unquote(root),
                 raw_captures,
                 unquote(actions_module),
                 initial_context,
                 unquote(capture_shapes),
                 locator: locator
               ) do
          {:ok, value, tree}
        end
      end

      defp lossless_match(input, context) do
        with {:ok, tokens} <- tokenize(input, context) do
          unquote(stream) = tokens |> Grammar.Source.significant(unquote(skip)) |> List.to_tuple()

          case unquote(run) do
            {:error, error} ->
              {:error, Grammar.Source.placed(error, input)}

            {:ok, pos, raw_captures} ->
              {raw_captures, record} = Ichor.Syntax.Record.root(unquote(root), pos, raw_captures)
              locator = Grammar.Source.Locator.new(unquote(stream), input)
              record = Ichor.Syntax.Record.unskipped(record, tokens, unquote(skip))
              {:ok, Ichor.Syntax.tree(record, tokens, unquote(skip)), raw_captures, locator}
          end
        end
      end
    end
  end

  @doc """
  The variable the trimmed token tuple is bound to, for `run` to read:
  unhygienic, since `run` is quoted in another module.
  """
  @spec stream_var() :: Macro.t()
  def stream_var, do: Macro.var(:stream, nil)

  @doc """
  `fn_name/2` clauses answering a state and a lookahead terminal with
  the table's list of actions (`[]` for none) -- the lookup
  `Grammar.LR.Lossless` takes, which the generated LR parser otherwise
  has no need of, its states being compiled into functions.
  """
  @spec action_defs(LRTable.t(), atom()) :: [Macro.t()]
  def action_defs(table, fn_name) do
    clauses =
      for {state, cells} <- table.action, {symbol, actions} <- cells do
        quote do
          defp unquote(fn_name)(unquote(state), unquote(symbol)),
            do: unquote(Macro.escape(actions))
        end
      end

    fallback =
      quote do
        defp unquote(fn_name)(_state, _terminal), do: []
      end

    clauses ++ [fallback]
  end
end
