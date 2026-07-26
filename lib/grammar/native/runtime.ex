defmodule Grammar.Native.Runtime do
  @moduledoc """
  Small, stable helpers shared by every `Grammar.Native`-generated
  module, so the generated code itself stays a thin list of direct
  function calls (the whole point of native codegen -- skipping
  interpretation overhead) instead of re-deriving PEG combinator
  semantics inline at every call site. Mirrors
  `Grammar.VM.CharInterpreter`/`Grammar.VM.TokenInterpreter`'s own
  semantics exactly (same backtracking discipline, same no-progress
  guard on `Star`), just expressed as plain function composition instead
  of a bytecode interpreter loop -- `Grammar.VM.Compiler`'s moduledoc
  describes the same combinators this module implements.

  Every rule/token-level combinator here operates on a `{:ok, pos,
  ref_stack, captures} | :fail` shape, where `captures` is a raw capture
  map in exactly the shape `Ichor.Actions` already expects (`{:token,
  name, text}` / `{:rule, name, sub_captures}` / `{:text, text}`) --
  generated code builds this map compositionally as it goes, rather than
  through a single mutable per-rule frame the way
  `Grammar.VM.TokenInterpreter` does, since plain Elixir recursion
  already gives every failed alternative's partial captures nowhere to
  leak to (they're just a discarded return value, never mutated shared
  state).
  """

  alias Grammar.VM.Token

  @type captures :: %{optional(atom()) => term()}
  @type rule_result :: {:ok, non_neg_integer(), [integer()], captures()} | :fail
  @type rule_fun :: (tuple(), non_neg_integer(), [integer()] -> rule_result())

  @type char_result :: {:ok, String.t(), String.t()} | :fail
  @type char_fun :: (String.t() -> char_result())

  # ---- char-level combinators -------------------------------------------
  # Simpler than the rule-level ones above: no captures, no ref_stack --
  # tokens can never contain a `Capture` or `Indent`, so a token body is
  # just text in, `{matched text, rest}` out.

  @spec in_ranges?(non_neg_integer(), [{non_neg_integer(), non_neg_integer()}]) :: boolean()
  def in_ranges?(cp, ranges), do: Enum.any?(ranges, fn {lo, hi} -> cp >= lo and cp <= hi end)

  @doc "Ordered choice: tries each of `funs` against `input` in order, short-circuiting on the first success (never evaluating later alternatives, same as PEG's own ordered choice)."
  @spec first_char_match([char_fun()], String.t()) :: char_result()
  def first_char_match([], _input), do: :fail

  def first_char_match([fun | rest], input) do
    case fun.(input) do
      {:ok, _, _} = ok -> ok
      :fail -> first_char_match(rest, input)
    end
  end

  @spec star_char(char_fun(), String.t(), String.t()) :: char_result()
  def star_char(fun, input, acc \\ "") do
    case fun.(input) do
      :fail ->
        {:ok, acc, input}

      {:ok, text, rest} ->
        if rest == input do
          {:ok, acc <> text, rest}
        else
          star_char(fun, rest, acc <> text)
        end
    end
  end

  @spec plus_char(char_fun(), String.t()) :: char_result()
  def plus_char(fun, input) do
    case fun.(input) do
      :fail -> :fail
      {:ok, text, rest} -> star_char(fun, rest, text)
    end
  end

  @spec opt_char(char_fun(), String.t()) :: char_result()
  def opt_char(fun, input) do
    case fun.(input) do
      {:ok, _, _} = ok -> ok
      :fail -> {:ok, "", input}
    end
  end

  @spec call_n_times_char(char_fun(), non_neg_integer(), String.t()) :: char_result()
  def call_n_times_char(_fun, 0, input), do: {:ok, "", input}

  def call_n_times_char(fun, n, input) do
    with {:ok, text1, rest1} <- fun.(input),
         {:ok, textN, restN} <- call_n_times_char(fun, n - 1, rest1) do
      {:ok, text1 <> textN, restN}
    else
      :fail -> :fail
    end
  end

  @spec rep_char(char_fun(), non_neg_integer(), non_neg_integer() | :infinity, String.t()) ::
          char_result()
  def rep_char(fun, min, :infinity, input) do
    with {:ok, mandatory, rest1} <- call_n_times_char(fun, min, input),
         {:ok, extra, restN} <- star_char(fun, rest1) do
      {:ok, mandatory <> extra, restN}
    else
      :fail -> :fail
    end
  end

  def rep_char(fun, min, max, input) do
    with {:ok, mandatory, rest1} <- call_n_times_char(fun, min, input),
         {:ok, extra, restN} <- call_n_times_char(&opt_char(fun, &1), max - min, rest1) do
      {:ok, mandatory <> extra, restN}
    else
      :fail -> :fail
    end
  end

  @spec and_pred_char(char_fun(), String.t()) :: char_result()
  def and_pred_char(fun, input) do
    case fun.(input) do
      {:ok, _, _} -> {:ok, "", input}
      :fail -> :fail
    end
  end

  @spec not_pred_char(char_fun(), String.t()) :: char_result()
  def not_pred_char(fun, input) do
    case fun.(input) do
      {:ok, _, _} -> :fail
      :fail -> {:ok, "", input}
    end
  end

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

  # ---- rule-level combinators -----------------------------------------------

  @doc "Ordered PEG choice: the first alternative that succeeds wins, tried in order."
  @spec try_alts([rule_fun()], tuple(), non_neg_integer(), [integer()]) :: rule_result()
  def try_alts([], _stream, _pos, _ref_stack), do: :fail

  def try_alts([f | rest], stream, pos, ref_stack) do
    case f.(stream, pos, ref_stack) do
      {:ok, _, _, _} = ok -> ok
      :fail -> try_alts(rest, stream, pos, ref_stack)
    end
  end

  @doc """
  Zero or more, greedy. Guards against a body that matches without
  consuming anything (`Grammar.VM.Compiler`'s own `test_progress` doc
  explains why this can't be left to the static lint alone) -- a
  zero-width success is still incorporated once, then the loop stops
  rather than looping forever.
  """
  @spec star(rule_fun(), tuple(), non_neg_integer(), [integer()], captures()) :: rule_result()
  def star(fun, stream, pos, ref_stack, acc \\ %{}) do
    case fun.(stream, pos, ref_stack) do
      :fail ->
        {:ok, pos, ref_stack, acc}

      {:ok, new_pos, new_ref_stack, caps} ->
        merged = merge_captures(acc, caps)

        if new_pos == pos do
          {:ok, new_pos, new_ref_stack, merged}
        else
          star(fun, stream, new_pos, new_ref_stack, merged)
        end
    end
  end

  @doc "One or more, greedy: one mandatory match, then `star/5` for the rest."
  @spec plus(rule_fun(), tuple(), non_neg_integer(), [integer()]) :: rule_result()
  def plus(fun, stream, pos, ref_stack) do
    case fun.(stream, pos, ref_stack) do
      :fail -> :fail
      {:ok, new_pos, new_ref_stack, caps} -> star(fun, stream, new_pos, new_ref_stack, caps)
    end
  end

  @doc "Zero or one: on failure, a zero-width success with no captures."
  @spec opt(rule_fun(), tuple(), non_neg_integer(), [integer()]) :: rule_result()
  def opt(fun, stream, pos, ref_stack) do
    case fun.(stream, pos, ref_stack) do
      {:ok, _, _, _} = ok -> ok
      :fail -> {:ok, pos, ref_stack, %{}}
    end
  end

  @doc "Calls `fun` exactly `n` times in sequence, merging captures, failing outward if any call fails."
  @spec call_n_times(rule_fun(), non_neg_integer(), tuple(), non_neg_integer(), [integer()]) ::
          rule_result()
  def call_n_times(_fun, 0, _stream, pos, ref_stack), do: {:ok, pos, ref_stack, %{}}

  def call_n_times(fun, n, stream, pos, ref_stack) do
    with {:ok, pos1, ref1, caps1} <- fun.(stream, pos, ref_stack),
         {:ok, posN, refN, capsN} <- call_n_times(fun, n - 1, stream, pos1, ref1) do
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
          [
            integer()
          ]
        ) :: rule_result()
  def rep(fun, min, :infinity, stream, pos, ref_stack) do
    with {:ok, pos1, ref1, caps1} <- call_n_times(fun, min, stream, pos, ref_stack),
         {:ok, posN, refN, capsN} <- star(fun, stream, pos1, ref1) do
      {:ok, posN, refN, merge_captures(caps1, capsN)}
    else
      :fail -> :fail
    end
  end

  def rep(fun, min, max, stream, pos, ref_stack) do
    opt_fun = fn s, p, r -> opt(fun, s, p, r) end

    with {:ok, pos1, ref1, caps1} <- call_n_times(fun, min, stream, pos, ref_stack),
         {:ok, posN, refN, capsN} <- call_n_times(opt_fun, max - min, stream, pos1, ref1) do
      {:ok, posN, refN, merge_captures(caps1, capsN)}
    else
      :fail -> :fail
    end
  end

  @doc "Matches one stream token named `name` at `pos`, advancing by one -- the raw building block every bare token reference compiles to."
  @spec match_token(tuple(), non_neg_integer(), atom()) ::
          {:ok, non_neg_integer(), String.t()} | :fail
  def match_token(stream, pos, name) do
    case token_at(stream, pos) do
      %Token{name: ^name, text: text} -> {:ok, pos + 1, text}
      _ -> :fail
    end
  end

  @doc "Positive lookahead: consumes nothing either way."
  @spec and_pred(rule_fun(), tuple(), non_neg_integer(), [integer()]) :: rule_result()
  def and_pred(fun, stream, pos, ref_stack) do
    case fun.(stream, pos, ref_stack) do
      {:ok, _, _, _} -> {:ok, pos, ref_stack, %{}}
      :fail -> :fail
    end
  end

  @doc "Negative lookahead: consumes nothing either way."
  @spec not_pred(rule_fun(), tuple(), non_neg_integer(), [integer()]) :: rule_result()
  def not_pred(fun, stream, pos, ref_stack) do
    case fun.(stream, pos, ref_stack) do
      {:ok, _, _, _} -> :fail
      :fail -> {:ok, pos, ref_stack, %{}}
    end
  end

  # ---- @indent / @samecol -----------------------------------------------

  @doc "`@indent(expr)`: the current token's column must exceed the enclosing reference column; pushes its own column as the new reference for `expr`, pops it back off afterward."
  @spec indent_enter(rule_fun(), tuple(), non_neg_integer(), [integer()]) :: rule_result()
  def indent_enter(fun, stream, pos, ref_stack) do
    case token_at(stream, pos) do
      nil ->
        :fail

      %Token{column: col} ->
        [ref | _] = ref_stack

        if col > ref do
          case fun.(stream, pos, [col | ref_stack]) do
            {:ok, new_pos, [_ | rest_ref], caps} -> {:ok, new_pos, rest_ref, caps}
            :fail -> :fail
          end
        else
          :fail
        end
    end
  end

  @doc "`@samecol(expr)`: the current token's column must exactly match the enclosing reference column."
  @spec samecol_check(rule_fun(), tuple(), non_neg_integer(), [integer()]) :: rule_result()
  def samecol_check(fun, stream, pos, ref_stack) do
    case token_at(stream, pos) do
      nil ->
        :fail

      %Token{column: col} ->
        [ref | _] = ref_stack
        if col == ref, do: fun.(stream, pos, ref_stack), else: :fail
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

  # ---- maximal munch ---------------------------------------------------------

  @doc """
  Picks the longest-matching candidate at the current lexer position,
  ties broken by declaration order (candidates tried in that order,
  replaced only on a *strictly* longer match). A zero-width match is
  never accepted as "the next token" -- accepting one would advance
  nothing and loop forever (mirrors `Grammar.VM.Lexer`'s own private
  `consider` helper's same guard exactly); such a token can still exist
  and be referenced from inside other tokens, it just can't win maximal
  munch on its own.
  """
  @spec pick_longest([{atom(), (-> {:ok, String.t(), String.t()} | :fail)}]) ::
          {:ok, atom(), String.t(), String.t()} | :fail
  def pick_longest(candidates) do
    Enum.reduce(candidates, nil, fn {name, fun}, best ->
      case fun.() do
        :fail ->
          best

        {:ok, text, rest} ->
          len = byte_size(text)

          cond do
            len == 0 -> best
            best == nil -> {name, text, rest, len}
            elem(best, 3) >= len -> best
            true -> {name, text, rest, len}
          end
      end
    end)
    |> case do
      nil -> :fail
      {name, text, rest, _len} -> {:ok, name, text, rest}
    end
  end

  @doc "Tokenizes `input` completely via maximal munch, or reports the first position nothing matches -- `get_candidates` rebuilds the per-token match attempts against whatever's left of the input at each position."
  @spec tokenize(
          (String.t() -> [{atom(), (-> {:ok, String.t(), String.t()} | :fail)}]),
          String.t()
        ) ::
          {:ok, [Token.t()]} | {:error, Ichor.Error.t()}
  def tokenize(get_candidates, input), do: do_tokenize(get_candidates, input, input, 1, 1, [])

  defp do_tokenize(_get_candidates, "", _source, _line, _col, acc), do: {:ok, Enum.reverse(acc)}

  defp do_tokenize(get_candidates, input, source, line, col, acc) do
    case pick_longest(get_candidates.(input)) do
      {:ok, name, text, rest} ->
        token = %Token{name: name, text: text, line: line, column: col}
        {new_line, new_col} = advance_line_col(text, line, col)
        do_tokenize(get_candidates, rest, source, new_line, new_col, [token | acc])

      :fail ->
        {:error,
         Ichor.Error.new(
           message: "no token matches here",
           stage: :lexer,
           line: line,
           column: col,
           source: source
         )}
    end
  end

  @spec advance_line_col(String.t(), pos_integer(), pos_integer()) ::
          {pos_integer(), pos_integer()}
  def advance_line_col(text, line, col) do
    Enum.reduce(String.to_charlist(text), {line, col}, fn
      ?\n, {line, _col} -> {line + 1, 1}
      _, {line, col} -> {line, col + 1}
    end)
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
