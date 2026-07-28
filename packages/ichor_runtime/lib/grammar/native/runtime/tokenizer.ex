defmodule Grammar.Native.Runtime.Tokenizer do
  @moduledoc """
  Char-level helpers shared by every `Grammar.Native.CharCompiler`-generated
  function, plus the maximal-munch driver `Grammar.Native.generate/2`'s own
  `lex_candidates/2` feeds into -- the Tokenizer stage of Aether's
  Reader/Tokenizer/Lexer/Parser split. No captures, no `ref_stack` --
  tokens can never contain a `Capture` or `Indent`, so a token body is
  just text in, `{matched text, rest}` out.
  """

  alias Grammar.VM.Token

  @type char_result :: {:ok, String.t(), String.t()} | :fail
  @type char_fun :: (String.t() -> char_result())

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

  # ---- maximal munch ---------------------------------------------------------

  @doc """
  Picks the longest-matching candidate at the current lexer position,
  ties broken by declaration order (candidates tried in that order,
  replaced only on a *strictly* longer match). A zero-width match is
  never accepted as "the next token" -- accepting one would advance
  nothing and loop forever (mirrors `Grammar.VM.Tokenizer`'s own private
  `consider` helper's same guard exactly); such a token can still exist
  and be referenced from inside other tokens, it just can't win maximal
  munch on its own.

  `capture` is `nil` for an ordinary candidate, or a `Grammar.IR.Custom
  Lexeme`-matched one's explicit override -- see `Grammar.VM.Token`.
  """
  @spec pick_longest([{atom(), (-> {:ok, String.t(), String.t(), term()} | :fail)}]) ::
          {:ok, atom(), String.t(), String.t(), term()} | :fail
  def pick_longest(candidates) do
    Enum.reduce(candidates, nil, fn {name, fun}, best ->
      case fun.() do
        :fail ->
          best

        {:ok, text, rest, capture} ->
          len = byte_size(text)

          cond do
            len == 0 -> best
            best == nil -> {name, text, rest, capture, len}
            elem(best, 4) >= len -> best
            true -> {name, text, rest, capture, len}
          end
      end
    end)
    |> case do
      nil -> :fail
      {name, text, rest, capture, _len} -> {:ok, name, text, rest, capture}
    end
  end

  @doc "Tokenizes `input` completely via maximal munch, or reports the first position nothing matches -- `get_candidates` rebuilds the per-token match attempts against whatever's left of the input at each position."
  @spec tokenize(
          (String.t() -> [{atom(), (-> {:ok, String.t(), String.t(), term()} | :fail)}]),
          String.t()
        ) ::
          {:ok, [Token.t()]} | {:error, Ichor.Error.t()}
  def tokenize(get_candidates, input),
    do: do_tokenize(get_candidates, input, input, 1, 1, [], :strict)

  @doc """
  Like `tokenize/2`, but tokenizes only as much of a *prefix* of `input`
  as it can -- stopping (successfully) the moment nothing matches,
  instead of failing. For `Ichor.CustomLexeme`'s re-lex-and-match
  primitive: the trailing bytes after wherever a dependency rule
  actually stops (an interpolated string's closing `}`, say) generally
  aren't valid tokens in their own right, and were never supposed to be
  -- they belong to whatever's scanning the *outer* token, not to this
  inner match.
  """
  @spec tokenize_prefix(
          (String.t() -> [{atom(), (-> {:ok, String.t(), String.t(), term()} | :fail)}]),
          String.t()
        ) :: {:ok, [Token.t()]}
  def tokenize_prefix(get_candidates, input),
    do: do_tokenize(get_candidates, input, input, 1, 1, [], :prefix)

  defp do_tokenize(_get_candidates, "", _source, _line, _col, acc, _mode),
    do: {:ok, Enum.reverse(acc)}

  defp do_tokenize(get_candidates, input, source, line, col, acc, mode) do
    case pick_longest(get_candidates.(input)) do
      {:ok, name, text, rest, capture} ->
        token = %Token{name: name, text: text, line: line, column: col, capture: capture}
        {new_line, new_col} = advance_line_col(text, line, col)
        do_tokenize(get_candidates, rest, source, new_line, new_col, [token | acc], mode)

      :fail when mode == :prefix ->
        {:ok, Enum.reverse(acc)}

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
end
