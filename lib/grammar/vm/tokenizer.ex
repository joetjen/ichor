defmodule Grammar.VM.Tokenizer do
  @moduledoc """
  Tokenizes a full input string against a `Grammar.VM.CharCompiler`
  program, using maximal munch: at each position, every declared token is
  tried, the longest match wins, ties are broken by declaration order.
  Trivia/skip tokens are emitted like any other -- filtering them out is
  the *parser*'s job, via the `Star(skip_token)` that `Aether.Parser`
  already spliced into rule bodies, not the lexer's.

  `custom_lexemes` (from `Grammar.VM.CharCompiler.compile/1`) names the
  tokens whose entire body is a `Grammar.IR.CustomLexeme` -- these are
  dispatched straight to `c:Ichor.CustomLexeme.scan/3` instead of run as
  bytecode, and can hand back a capture override (embedded in the
  resulting `Grammar.VM.Token.capture`) alongside their matched text.
  `rule_program`/`context` only exist to support that dispatch (building
  the re-lex-and-match-a-rule `rule_matchers` its callback receives) --
  every other candidate ignores them completely.
  """

  alias Grammar.VM.{CharInterpreter, Token, TokenInterpreter}
  alias Ichor.Error

  @doc "Tokenizes `input` completely, or reports the first position nothing matches."
  @spec tokenize(
          Grammar.VM.Program.t(),
          %{atom() => Grammar.VM.CharCompiler.custom_lexeme()},
          [atom()],
          Grammar.VM.Program.t(),
          term(),
          String.t(),
          String.t() | nil
        ) :: {:ok, [Token.t()]} | {:error, Error.t()}
  def tokenize(program, custom_lexemes, token_order, rule_program, context, input, file \\ nil) do
    do_tokenize(
      program,
      custom_lexemes,
      token_order,
      rule_program,
      context,
      input,
      input,
      1,
      1,
      file,
      [],
      :strict
    )
  end

  @doc """
  Like `tokenize/7`, but tokenizes only as much of a *prefix* of `input`
  as it can -- stopping (successfully) the moment nothing matches,
  instead of failing. For `Ichor.CustomLexeme`'s re-lex-and-match
  primitive: the trailing bytes after wherever a dependency rule
  actually stops (an interpolated string's closing `}`, say) generally
  aren't valid tokens in their own right, and were never supposed to be
  -- they belong to whatever's scanning the *outer* token, not to this
  inner match.
  """
  @spec tokenize_prefix(
          Grammar.VM.Program.t(),
          %{atom() => Grammar.VM.CharCompiler.custom_lexeme()},
          [atom()],
          Grammar.VM.Program.t(),
          term(),
          String.t()
        ) :: {:ok, [Token.t()]}
  def tokenize_prefix(program, custom_lexemes, token_order, rule_program, context, input) do
    do_tokenize(
      program,
      custom_lexemes,
      token_order,
      rule_program,
      context,
      input,
      input,
      1,
      1,
      nil,
      [],
      :prefix
    )
  end

  defp do_tokenize(
         _program,
         _custom_lexemes,
         _token_order,
         _rule_program,
         _context,
         "",
         _source,
         _line,
         _col,
         _file,
         acc,
         _mode
       ) do
    {:ok, Enum.reverse(acc)}
  end

  defp do_tokenize(
         program,
         custom_lexemes,
         token_order,
         rule_program,
         context,
         input,
         source,
         line,
         col,
         file,
         acc,
         mode
       ) do
    case best_match(program, custom_lexemes, token_order, rule_program, context, input) do
      {:ok, name, text, capture} ->
        token = %Token{name: name, text: text, line: line, column: col, capture: capture}
        {new_line, new_col} = advance(text, line, col)
        rest = binary_part(input, byte_size(text), byte_size(input) - byte_size(text))

        do_tokenize(
          program,
          custom_lexemes,
          token_order,
          rule_program,
          context,
          rest,
          source,
          new_line,
          new_col,
          file,
          [token | acc],
          mode
        )

      :none when mode == :prefix ->
        {:ok, Enum.reverse(acc)}

      :none ->
        {:error,
         Error.new(
           message: "no token matches here",
           stage: :lexer,
           file: file,
           line: line,
           column: col,
           source: source
         )}
    end
  end

  defp best_match(program, custom_lexemes, token_order, rule_program, context, input) do
    token_order
    |> Enum.reduce(:none, fn name, best ->
      case Map.fetch(custom_lexemes, name) do
        {:ok, {module, function, deps}} ->
          rule_matchers =
            build_lexeme_rule_matchers(
              deps,
              program,
              custom_lexemes,
              token_order,
              rule_program,
              context
            )

          case apply(module, function, [input, context, rule_matchers]) do
            {:ok, text, _rest, capture} -> consider(best, name, byte_size(text), input, capture)
            :fail -> best
          end

        :error ->
          entry = Map.fetch!(program.entry_points, name)

          case CharInterpreter.run(program.instructions, entry, input) do
            {:ok, remaining} ->
              consider(best, name, byte_size(input) - byte_size(remaining), input, nil)

            :fail ->
              best
          end
      end
    end)
    |> case do
      :none -> :none
      {name, text, capture} -> {:ok, name, text, capture}
    end
  end

  # A `Grammar.IR.CustomLexeme`'s dependency, re-lexed-and-matched from
  # scratch against whatever's left of the input -- the primitive
  # `Ichor.CustomLexeme.scan/3` needs to consume an embedded expression
  # (a string-interpolation's `#{...}`) without knowing anything about
  # how this grammar's own lexer/parser are actually compiled.
  defp build_lexeme_rule_matchers(
         deps,
         char_program,
         custom_lexemes,
         token_order,
         rule_program,
         context
       ) do
    Map.new(deps, fn name ->
      entry = Map.fetch!(rule_program.entry_points, name)

      {name,
       fn input ->
         {:ok, tokens} =
           tokenize_prefix(
             char_program,
             custom_lexemes,
             token_order,
             rule_program,
             context,
             input
           )

         stream = List.to_tuple(tokens)

         case TokenInterpreter.run_from(rule_program.instructions, entry, stream, 0, context) do
           {:ok, token_pos, raw_captures} ->
             {consumed, _rest} = Enum.split(tokens, token_pos)
             text = Enum.map_join(consumed, "", & &1.text)
             rest = binary_part(input, byte_size(text), byte_size(input) - byte_size(text))
             {:ok, text, rest, {:rule, name, raw_captures}}

           :fail ->
             :fail
         end
       end}
    end)
  end

  # Zero-width matches are never accepted as "the next token" -- accepting
  # one would advance nothing and loop forever. Such a token can still
  # exist and be referenced from inside other tokens; it just can't win
  # maximal munch on its own.
  defp consider(best, _name, 0, _input, _capture), do: best

  defp consider(:none, name, consumed, input, capture),
    do: {name, binary_part(input, 0, consumed), capture}

  defp consider({_, best_text, _} = best, name, consumed, input, capture) do
    if consumed > byte_size(best_text),
      do: {name, binary_part(input, 0, consumed), capture},
      else: best
  end

  defp advance(text, line, col) do
    Enum.reduce(String.to_charlist(text), {line, col}, fn
      ?\n, {line, _col} -> {line + 1, 1}
      _, {line, col} -> {line, col + 1}
    end)
  end
end
