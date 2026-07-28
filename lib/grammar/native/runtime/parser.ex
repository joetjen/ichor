defmodule Grammar.Native.Runtime.Parser do
  @moduledoc """
  Rule-level helpers shared by every `Grammar.Native.RuleCompiler`-generated
  function -- the Parser stage of Aether's Reader/Tokenizer/Lexer/Parser
  split. Mirrors `Grammar.VM.TokenInterpreter`'s own semantics exactly
  (same backtracking discipline, same no-progress guard on `Star`), just
  expressed as plain function composition instead of a bytecode
  interpreter loop -- `Grammar.VM.Compiler`'s moduledoc describes the
  same combinators this module implements.

  Every combinator here operates on a `{:ok, pos, ref_stack, captures} |
  :fail` shape, where `captures` is a raw capture map in exactly the
  shape `Ichor.Actions` already expects (`{:token, name, text}` /
  `{:rule, name, sub_captures}` / `{:text, text}`) -- generated code
  builds this map compositionally as it goes, rather than through a
  single mutable per-rule frame the way `Grammar.VM.TokenInterpreter`
  does, since plain Elixir recursion already gives every failed
  alternative's partial captures nowhere to leak to (they're just a
  discarded return value, never mutated shared state).
  """

  alias Grammar.VM.Token

  @type captures :: %{optional(atom()) => term()}
  @type rule_result :: {:ok, non_neg_integer(), [integer()], captures()} | :fail
  @type rule_fun :: (tuple(), non_neg_integer(), [integer()], term() -> rule_result())

  # ---- capture merging (matches Grammar.VM.TokenInterpreter's own private
  # merge_capture/3) ----

  @doc """
  Folds every key of `new` into `acc`, list-appending (or list-wrapping)
  on repeat capture names -- the same rule a rule's own capture frame
  follows in the VM (`Grammar.VM.TokenInterpreter`'s own private
  `merge_capture` helper).

  Unlike that VM function, this one has to merge whole *subtree*
  capture maps at once (a `Seq`/`Star` node's already-accumulated
  captures), not a single new occurrence at a time -- so a value that's
  already a list (built up by a nested `Star`/`Plus`/`Rep` sharing this
  same capture name) has to be flattened into the result rather than
  wrapped as one more element, or `[a, b, c]` merged against a sibling
  `d` would wrongly become `[d, [a, b, c]]` instead of `[d, a, b, c]`.
  A raw capture value is always a `{:token, ...}` / `{:rule, ...}` /
  `{:text, ...}` tuple, never a bare list on its own, so "the value is
  a list" unambiguously means "already an accumulation," never "one
  occurrence that happens to look like a list."
  """
  @spec merge_captures(captures(), captures()) :: captures()
  def merge_captures(acc, new) do
    Enum.reduce(new, acc, fn {k, v}, acc -> merge_one(acc, k, v) end)
  end

  defp merge_one(acc, k, v) do
    case Map.fetch(acc, k) do
      :error -> Map.put(acc, k, v)
      {:ok, existing} -> Map.put(acc, k, as_list(existing) ++ as_list(v))
    end
  end

  defp as_list(v) when is_list(v), do: v
  defp as_list(v), do: [v]

  @doc "Ordered PEG choice: the first alternative that succeeds wins, tried in order."
  @spec try_alts([rule_fun()], tuple(), non_neg_integer(), [integer()], term()) :: rule_result()
  def try_alts([], _stream, _pos, _ref_stack, _context), do: :fail

  def try_alts([f | rest], stream, pos, ref_stack, context) do
    case f.(stream, pos, ref_stack, context) do
      {:ok, _, _, _} = ok -> ok
      :fail -> try_alts(rest, stream, pos, ref_stack, context)
    end
  end

  @doc """
  Zero or more, greedy. Guards against a body that matches without
  consuming anything (`Grammar.VM.Compiler`'s own `test_progress` doc
  explains why this can't be left to the static lint alone) -- a
  zero-width success is still incorporated once, then the loop stops
  rather than looping forever.
  """
  @spec star(rule_fun(), tuple(), non_neg_integer(), [integer()], term(), captures()) ::
          rule_result()
  def star(fun, stream, pos, ref_stack, context, acc \\ %{}) do
    case fun.(stream, pos, ref_stack, context) do
      :fail ->
        {:ok, pos, ref_stack, acc}

      {:ok, new_pos, new_ref_stack, caps} ->
        merged = merge_captures(acc, caps)

        if new_pos == pos do
          {:ok, new_pos, new_ref_stack, merged}
        else
          star(fun, stream, new_pos, new_ref_stack, context, merged)
        end
    end
  end

  @doc "One or more, greedy: one mandatory match, then `star/6` for the rest."
  @spec plus(rule_fun(), tuple(), non_neg_integer(), [integer()], term()) :: rule_result()
  def plus(fun, stream, pos, ref_stack, context) do
    case fun.(stream, pos, ref_stack, context) do
      :fail ->
        :fail

      {:ok, new_pos, new_ref_stack, caps} ->
        star(fun, stream, new_pos, new_ref_stack, context, caps)
    end
  end

  @doc "Zero or one: on failure, a zero-width success with no captures."
  @spec opt(rule_fun(), tuple(), non_neg_integer(), [integer()], term()) :: rule_result()
  def opt(fun, stream, pos, ref_stack, context) do
    case fun.(stream, pos, ref_stack, context) do
      {:ok, _, _, _} = ok -> ok
      :fail -> {:ok, pos, ref_stack, %{}}
    end
  end

  @doc "Calls `fun` exactly `n` times in sequence, merging captures, failing outward if any call fails."
  @spec call_n_times(
          rule_fun(),
          non_neg_integer(),
          tuple(),
          non_neg_integer(),
          [integer()],
          term()
        ) ::
          rule_result()
  def call_n_times(_fun, 0, _stream, pos, ref_stack, _context), do: {:ok, pos, ref_stack, %{}}

  def call_n_times(fun, n, stream, pos, ref_stack, context) do
    with {:ok, pos1, ref1, caps1} <- fun.(stream, pos, ref_stack, context),
         {:ok, posN, refN, capsN} <- call_n_times(fun, n - 1, stream, pos1, ref1, context) do
      {:ok, posN, refN, merge_captures(caps1, capsN)}
    else
      :fail -> :fail
    end
  end

  @doc "Bounded repetition `{n,m}`: `min` mandatory calls, then up to `max - min` more (or unbounded, when `max == :infinity`)."
  @spec rep(
          rule_fun(),
          non_neg_integer(),
          non_neg_integer() | :infinity,
          tuple(),
          non_neg_integer(),
          [integer()],
          term()
        ) :: rule_result()
  def rep(fun, min, :infinity, stream, pos, ref_stack, context) do
    with {:ok, pos1, ref1, caps1} <- call_n_times(fun, min, stream, pos, ref_stack, context),
         {:ok, posN, refN, capsN} <- star(fun, stream, pos1, ref1, context) do
      {:ok, posN, refN, merge_captures(caps1, capsN)}
    else
      :fail -> :fail
    end
  end

  def rep(fun, min, max, stream, pos, ref_stack, context) do
    opt_fun = fn s, p, r, c -> opt(fun, s, p, r, c) end

    with {:ok, pos1, ref1, caps1} <- call_n_times(fun, min, stream, pos, ref_stack, context),
         {:ok, posN, refN, capsN} <-
           call_n_times(opt_fun, max - min, stream, pos1, ref1, context) do
      {:ok, posN, refN, merge_captures(caps1, capsN)}
    else
      :fail -> :fail
    end
  end

  @doc """
  Matches one stream token named `name` at `pos`, advancing by one -- the
  raw building block every bare token reference compiles to. `capture`
  is the token's own override (see `Grammar.VM.Token`) -- `nil` unless a
  `Grammar.IR.CustomLexeme` matched it with one attached.
  """
  @spec match_token(tuple(), non_neg_integer(), atom()) ::
          {:ok, non_neg_integer(), String.t(), term()} | :fail
  def match_token(stream, pos, name) do
    case token_at(stream, pos) do
      %Token{name: ^name, text: text, capture: capture} -> {:ok, pos + 1, text, capture}
      _ -> :fail
    end
  end

  @doc "Positive lookahead: consumes nothing either way."
  @spec and_pred(rule_fun(), tuple(), non_neg_integer(), [integer()], term()) :: rule_result()
  def and_pred(fun, stream, pos, ref_stack, context) do
    case fun.(stream, pos, ref_stack, context) do
      {:ok, _, _, _} -> {:ok, pos, ref_stack, %{}}
      :fail -> :fail
    end
  end

  @doc "Negative lookahead: consumes nothing either way."
  @spec not_pred(rule_fun(), tuple(), non_neg_integer(), [integer()], term()) :: rule_result()
  def not_pred(fun, stream, pos, ref_stack, context) do
    case fun.(stream, pos, ref_stack, context) do
      {:ok, _, _, _} -> :fail
      :fail -> {:ok, pos, ref_stack, %{}}
    end
  end

  # ---- @indent / @samecol -----------------------------------------------

  @doc "`@indent(expr)`: the current token's column must exceed the enclosing reference column; pushes its own column as the new reference for `expr`, pops it back off afterward."
  @spec indent_enter(rule_fun(), tuple(), non_neg_integer(), [integer()], term()) :: rule_result()
  def indent_enter(fun, stream, pos, ref_stack, context) do
    case token_at(stream, pos) do
      nil ->
        :fail

      %Token{column: col} ->
        [ref | _] = ref_stack

        if col > ref do
          case fun.(stream, pos, [col | ref_stack], context) do
            {:ok, new_pos, [_ | rest_ref], caps} -> {:ok, new_pos, rest_ref, caps}
            :fail -> :fail
          end
        else
          :fail
        end
    end
  end

  @doc "`@samecol(expr)`: the current token's column must exactly match the enclosing reference column."
  @spec samecol_check(rule_fun(), tuple(), non_neg_integer(), [integer()], term()) ::
          rule_result()
  def samecol_check(fun, stream, pos, ref_stack, context) do
    case token_at(stream, pos) do
      nil ->
        :fail

      %Token{column: col} ->
        [ref | _] = ref_stack
        if col == ref, do: fun.(stream, pos, ref_stack, context), else: :fail
    end
  end

  @spec token_at(tuple(), non_neg_integer()) :: Token.t() | nil
  def token_at(stream, pos) when pos < tuple_size(stream), do: elem(stream, pos)
  def token_at(_stream, _pos), do: nil

  @doc "Concatenates the raw text of every token in `[start_pos, end_pos)` -- the `:text` capture kind's raw value."
  @spec concat_text(tuple(), non_neg_integer(), non_neg_integer()) :: String.t()
  def concat_text(stream, start_pos, end_pos) do
    Enum.map_join(start_pos..(end_pos - 1)//1, "", fn i -> elem(stream, i).text end)
  end

  @doc """
  Skips tokens named `skip_name` at `pos` (mirrors `Grammar.VM`'s own
  private `skip_leading_trivia/3`, for the same `run_sequence` case:
  between two top-level matches there's no enclosing sequence for
  `Aether.Parser`'s skip-splicing to have spliced anything into, so a
  leading `@skip` token here is genuinely unconsumed leftover from the
  *previous* top-level match). `skip_name` is `nil` for a `@noskip`
  grammar, in which case `pos` is returned unchanged.
  """
  @spec skip_leading_trivia(tuple(), non_neg_integer(), atom() | nil) :: non_neg_integer()
  def skip_leading_trivia(_stream, pos, nil), do: pos

  def skip_leading_trivia(stream, pos, skip_name) do
    case token_at(stream, pos) do
      %Token{name: ^skip_name} -> skip_leading_trivia(stream, pos + 1, skip_name)
      _ -> pos
    end
  end

  @doc "A token stream matched only a prefix of the input -- the same error `Grammar.VM`'s own `match/2` reports."
  @spec unexpected_token_error(tuple(), non_neg_integer(), String.t()) :: Ichor.Error.t()
  def unexpected_token_error(stream, pos, input) do
    %Token{text: text, line: line, column: col} = elem(stream, pos)

    Ichor.Error.new(
      message: "unexpected #{inspect(text)} -- did not expect more input here",
      stage: :parser,
      line: line,
      column: col,
      source: input
    )
  end
end
