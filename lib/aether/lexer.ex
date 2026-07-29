defmodule Aether.Lexer do
  @moduledoc """
  Turns `.aether` source text into a flat list of `Aether.Token`s.

  Whitespace and `;`-to-end-of-line comments are trivia here -- they
  separate tokens but never appear in the output. This is Ichor's own
  front-end lexer, entirely separate from the `@skip`/`@noskip` machinery
  a *compiled* Aether grammar applies to *its own* rules -- that splicing
  happens later, in `Aether.Parser`.
  """

  alias Aether.Token
  alias Ichor.Error

  @pragmas %{
    "grammar" => :at_grammar,
    "root" => :at_root,
    "skip" => :at_skip,
    "noskip" => :at_noskip,
    "case_insensitive" => :at_case_insensitive,
    "indent" => :at_indent,
    "samecol" => :at_samecol,
    "native" => :at_native,
    "hint" => :at_hint,
    "keywords" => :at_keywords,
    "refine" => :at_refine,
    "engine" => :at_engine
  }

  @posix_classes %{
    "alpha" => :alpha,
    "alnum" => :alnum,
    "digit" => :digit,
    "space" => :space,
    "hex" => :hex
  }

  @doc """
  Lexes `source` into a token stream, terminated by a single `:eof` token.
  `file` is carried into any `Ichor.Error` produced, purely for display.
  """
  @spec lex(String.t(), String.t() | nil) :: {:ok, [Token.t()]} | {:error, Error.t()}
  def lex(source, file \\ nil) do
    scan(source, source, 1, 1, file, [])
  end

  # ---- driver -------------------------------------------------------------

  defp scan("", _source, line, col, _file, acc) do
    {:ok, Enum.reverse([%Token{type: :eof, line: line, column: col} | acc])}
  end

  defp scan(<<c, rest::binary>>, source, line, col, file, acc) when c in [?\s, ?\t, ?\r] do
    scan(rest, source, line, col + 1, file, acc)
  end

  defp scan(<<"\n", rest::binary>>, source, line, _col, file, acc) do
    scan(rest, source, line + 1, 1, file, acc)
  end

  defp scan(<<";", rest::binary>>, source, line, col, file, acc) do
    {rest, col} = skip_comment(rest, col)
    scan(rest, source, line, col, file, acc)
  end

  defp scan(<<":=", rest::binary>>, source, line, col, file, acc) do
    emit(rest, source, line, col, 2, file, acc, :define)
  end

  defp scan(<<"->", rest::binary>>, source, line, col, file, acc) do
    emit(rest, source, line, col, 2, file, acc, :arrow)
  end

  defp scan(<<"|", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :pipe)

  defp scan(<<"*", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :star)

  defp scan(<<"+", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :plus)

  defp scan(<<"?", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :question)

  defp scan(<<"{", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :lbrace)

  defp scan(<<"}", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :rbrace)

  defp scan(<<",", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :comma)

  defp scan(<<"&", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :amp)

  defp scan(<<"!", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :bang)

  defp scan(<<":", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :colon)

  defp scan(<<"(", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :lparen)

  defp scan(<<")", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :rparen)

  defp scan(<<"~", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :tilde)

  defp scan(<<".", rest::binary>>, source, line, col, file, acc),
    do: emit(rest, source, line, col, 1, file, acc, :dot)

  defp scan(<<"@", rest::binary>>, source, line, col, file, acc) do
    {name, rest2} = take_while(rest, &ident_char?/1)

    case Map.fetch(@pragmas, name) do
      {:ok, type} ->
        emit(rest2, source, line, col, String.length(name) + 1, file, acc, type)

      :error ->
        lex_error(source, file, line, col, "unknown pragma \"@#{name}\"")
    end
  end

  defp scan(<<"\"", rest::binary>>, source, line, col, file, acc) do
    with {:ok, text, rest2, end_line, end_col} <- scan_string(rest, line, col + 1) do
      {suffix, rest3, end_col} = scan_string_suffix(rest2, end_col)

      case suffix do
        {:ok, case_flag} ->
          value = %{text: text, case: case_flag}
          scan(rest3, source, end_line, end_col, file, [token(:string, value, line, col) | acc])

        :error ->
          lex_error(
            source,
            file,
            end_line,
            end_col,
            "invalid string suffix -- only \"i\" or \"cs\" are valid"
          )
      end
    else
      {:error, msg, err_line, err_col} -> lex_error(source, file, err_line, err_col, msg)
    end
  end

  defp scan(<<"[", rest::binary>>, source, line, col, file, acc) do
    case scan_char_class(rest, line, col + 1) do
      {:ok, value, rest2, end_line, end_col} ->
        scan(rest2, source, end_line, end_col, file, [token(:char_class, value, line, col) | acc])

      {:error, msg, err_line, err_col} ->
        lex_error(source, file, err_line, err_col, msg)
    end
  end

  defp scan(<<"/", rest::binary>>, source, line, col, file, acc) do
    case scan_regex(rest, line, col + 1) do
      {:ok, pattern, rest2, end_line, end_col} ->
        scan(rest2, source, end_line, end_col, file, [token(:regex, pattern, line, col) | acc])

      {:error, msg, err_line, err_col} ->
        lex_error(source, file, err_line, err_col, msg)
    end
  end

  defp scan(<<c, rest::binary>>, source, line, col, file, acc) when c in ?0..?9 do
    {digits, rest2} = take_while(rest, &(&1 in ?0..?9))
    text = <<c>> <> digits

    emit(
      rest2,
      source,
      line,
      col,
      String.length(text),
      file,
      acc,
      :number,
      String.to_integer(text)
    )
  end

  defp scan(<<c, _::binary>> = input, source, line, col, file, acc)
       when c in ?A..?Z or c == ?_ or c in ?a..?z do
    {text, rest} = take_while(input, &ident_char?/1)

    case classify_ident(text) do
      {:ok, type} ->
        emit(rest, source, line, col, String.length(text), file, acc, type, text)

      {:error, msg} ->
        lex_error(source, file, line, col, msg)
    end
  end

  defp scan(<<c::utf8, _::binary>>, source, line, col, file, _acc) do
    lex_error(source, file, line, col, "unexpected character #{inspect(<<c::utf8>>)}")
  end

  # ---- small emit/error helpers --------------------------------------------

  defp emit(rest, source, line, col, width, file, acc, type, value \\ nil) do
    scan(rest, source, line, col + width, file, [token(type, value, line, col) | acc])
  end

  defp token(type, value, line, col),
    do: %Token{type: type, value: value, line: line, column: col}

  defp lex_error(source, file, line, col, message) do
    {:error,
     Error.new(
       message: message,
       stage: :lexer,
       file: file,
       line: line,
       column: col,
       source: source
     )}
  end

  defp take_while(binary, fun), do: take_while(binary, fun, [])

  defp take_while(<<c::utf8, rest::binary>>, fun, acc) do
    if fun.(c) do
      take_while(rest, fun, [c | acc])
    else
      {acc |> Enum.reverse() |> List.to_string(), <<c::utf8, rest::binary>>}
    end
  end

  defp take_while(<<>>, _fun, acc), do: {acc |> Enum.reverse() |> List.to_string(), <<>>}

  defp ident_char?(c), do: c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c == ?_ or c == ?-

  defp skip_comment(<<"\n", _::binary>> = rest, col), do: {rest, col}
  defp skip_comment(<<>>, col), do: {<<>>, col}
  defp skip_comment(<<_c::utf8, rest::binary>>, col), do: skip_comment(rest, col + 1)

  # ---- identifier classification -------------------------------------------
  # ALL_UPPERCASE names a token, snake_case/kebab-case names a rule -- this
  # is the one syntactic distinction the whole language hinges on (see
  # `Aether.Parser`), so it's enforced here rather than left for the parser
  # to discover as a semantic error later.

  defp classify_ident(text) do
    cond do
      text =~ ~r/^[A-Z_][A-Z0-9_]*$/ ->
        {:ok, :upper_ident}

      text =~ ~r/^[a-z][a-z0-9_-]*$/ ->
        {:ok, :lower_ident}

      true ->
        {:error,
         "invalid identifier #{inspect(text)} -- must be ALL_UPPERCASE (a token) or snake_case/kebab-case (a rule)"}
    end
  end

  # ---- string literals ------------------------------------------------------

  defp scan_string(rest, line, col), do: scan_string(rest, line, col, [])

  defp scan_string(<<"\"", rest::binary>>, line, col, acc) do
    {:ok, acc |> Enum.reverse() |> List.to_string(), rest, line, col + 1}
  end

  defp scan_string(<<"\\", rest::binary>>, line, col, acc) do
    case decode_escape(rest, line, col + 1) do
      {:ok, cp, rest2, line2, col2} -> scan_string(rest2, line2, col2, [cp | acc])
      {:error, msg, err_line, err_col} -> {:error, msg, err_line, err_col}
    end
  end

  defp scan_string(<<"\n", rest::binary>>, line, _col, acc) do
    scan_string(rest, line + 1, 1, [?\n | acc])
  end

  defp scan_string(<<c::utf8, rest::binary>>, line, col, acc) do
    scan_string(rest, line, col + 1, [c | acc])
  end

  defp scan_string(<<>>, line, col, _acc) do
    {:error, "unterminated string literal", line, col}
  end

  defp scan_string_suffix(<<"cs", rest::binary>>, col) do
    if ident_start_boundary?(rest),
      do: {{:ok, :sensitive}, rest, col + 2},
      else: {:error, rest, col}
  end

  defp scan_string_suffix(<<"i", rest::binary>>, col) do
    if ident_start_boundary?(rest),
      do: {{:ok, :insensitive}, rest, col + 1},
      else: {:error, rest, col}
  end

  defp scan_string_suffix(rest, col), do: {{:ok, :default}, rest, col}

  defp ident_start_boundary?(<<c::utf8, _::binary>>),
    do: not (c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c == ?_)

  defp ident_start_boundary?(<<>>), do: true

  # ---- escapes: \n \r \t \\ \" \[ \] \xHH \u{H+} ----------------------------

  defp decode_escape(<<"n", rest::binary>>, line, col), do: {:ok, ?\n, rest, line, col + 1}
  defp decode_escape(<<"r", rest::binary>>, line, col), do: {:ok, ?\r, rest, line, col + 1}
  defp decode_escape(<<"t", rest::binary>>, line, col), do: {:ok, ?\t, rest, line, col + 1}
  defp decode_escape(<<"\\", rest::binary>>, line, col), do: {:ok, ?\\, rest, line, col + 1}
  defp decode_escape(<<"\"", rest::binary>>, line, col), do: {:ok, ?", rest, line, col + 1}
  defp decode_escape(<<"[", rest::binary>>, line, col), do: {:ok, ?[, rest, line, col + 1}
  defp decode_escape(<<"]", rest::binary>>, line, col), do: {:ok, ?], rest, line, col + 1}
  defp decode_escape(<<"/", rest::binary>>, line, col), do: {:ok, ?/, rest, line, col + 1}

  defp decode_escape(<<"x", h1, h2, rest::binary>>, line, col) do
    if hex_digit?(h1) and hex_digit?(h2) do
      {:ok, String.to_integer(<<h1, h2>>, 16), rest, line, col + 3}
    else
      {:error, "invalid \\x escape -- expected exactly two hex digits", line, col}
    end
  end

  defp decode_escape(<<"x", _::binary>>, line, col) do
    {:error, "invalid \\x escape -- expected exactly two hex digits", line, col}
  end

  defp decode_escape(<<"u", "{", rest::binary>>, line, col) do
    {digits, rest2} = take_while(rest, &hex_digit?/1)

    case rest2 do
      <<"}", rest3::binary>> when digits != "" ->
        {:ok, String.to_integer(digits, 16), rest3, line, col + 2 + String.length(digits) + 1}

      _ ->
        {:error, "invalid \\u{...} escape -- expected one or more hex digits followed by \"}\"",
         line, col}
    end
  end

  # Any other punctuation/symbol escapes to itself -- e.g. `\^`, `\-`, `\*` --
  # needed so char classes (and the /pattern/ dialect built on the same
  # primitives) can escape their own metacharacters, beyond the handful of
  # named escapes above.
  defp decode_escape(<<c::utf8, rest::binary>>, line, col)
       when not (c in ?a..?z or c in ?A..?Z or c in ?0..?9) do
    {:ok, c, rest, line, col + 1}
  end

  defp decode_escape(_, line, col) do
    {:error, "unrecognized escape sequence", line, col}
  end

  defp hex_digit?(c), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F

  # ---- character classes: [...] / [^...] / [:posix:] ------------------------

  defp scan_char_class(<<"^", rest::binary>>, line, col) do
    scan_char_class_items(rest, line, col + 1, true, [])
  end

  defp scan_char_class(rest, line, col) do
    scan_char_class_items(rest, line, col, false, [])
  end

  defp scan_char_class_items(<<"]", rest::binary>>, line, col, negate, items) do
    {:ok, %{negate: negate, items: Enum.reverse(items)}, rest, line, col + 1}
  end

  defp scan_char_class_items(<<>>, line, col, _negate, _items) do
    {:error, "unterminated character class", line, col}
  end

  defp scan_char_class_items(<<"[:", rest::binary>>, line, col, negate, items) do
    {name, rest2} = take_while(rest, &(&1 in ?a..?z))

    case {Map.fetch(@posix_classes, name), rest2} do
      {{:ok, posix}, <<":]", rest3::binary>>} ->
        width = 2 + String.length(name) + 2
        scan_char_class_items(rest3, line, col + width, negate, [{:posix, posix} | items])

      {:error, _} ->
        {:error, "unknown POSIX class \"[:#{name}:]\"", line, col}

      _ ->
        {:error, "malformed POSIX class -- expected \"[:name:]\"", line, col}
    end
  end

  defp scan_char_class_items(rest, line, col, negate, items) do
    with {:ok, first, rest2, line2, col2} <- scan_class_atom(rest, line, col) do
      case rest2 do
        # A "-" immediately followed by "]" is a literal trailing dash
        # (e.g. `[a-z-]`), not the start of a range -- only treat "-" as a
        # range operator when something other than the closing bracket
        # follows it.
        <<"-", after_dash::binary>> when after_dash != <<>> ->
          if String.starts_with?(after_dash, "]") do
            scan_char_class_items(rest2, line2, col2, negate, [{:char, first} | items])
          else
            with {:ok, last, rest3, line3, col3} <- scan_class_atom(after_dash, line2, col2 + 1) do
              scan_char_class_items(rest3, line3, col3, negate, [{:range, first, last} | items])
            end
          end

        _ ->
          scan_char_class_items(rest2, line2, col2, negate, [{:char, first} | items])
      end
    end
  end

  defp scan_class_atom(<<"\\", rest::binary>>, line, col) do
    decode_escape(rest, line, col + 1)
  end

  defp scan_class_atom(<<c::utf8, rest::binary>>, line, col) do
    {:ok, c, rest, line, col + 1}
  end

  defp scan_class_atom(<<>>, line, col) do
    {:error, "unterminated character class", line, col}
  end

  # ---- /pattern/ regex literals ---------------------------------------------
  # The lexer only finds the closing delimiter; `Aether.Parser` desugars the
  # raw pattern text afterwards (it needs the shared predefined-token
  # override state, which only the parser tracks).

  defp scan_regex(rest, line, col), do: scan_regex(rest, line, col, false, [])

  # `in_class` tracks whether we're inside a `[...]` character class, so an
  # unescaped "/" there (e.g. `/[a/b]/`) doesn't end the pattern early.
  defp scan_regex(<<"/", rest::binary>>, line, col, false, acc) do
    {:ok, acc |> Enum.reverse() |> List.to_string(), rest, line, col + 1}
  end

  defp scan_regex(<<"\\", c::utf8, rest::binary>>, line, col, in_class, acc) do
    scan_regex(rest, line, col + 2, in_class, [c, ?\\ | acc])
  end

  defp scan_regex(<<"[", rest::binary>>, line, col, _in_class, acc) do
    scan_regex(rest, line, col + 1, true, [?[ | acc])
  end

  defp scan_regex(<<"]", rest::binary>>, line, col, _in_class, acc) do
    scan_regex(rest, line, col + 1, false, [?] | acc])
  end

  defp scan_regex(<<"\n", rest::binary>>, line, _col, in_class, acc) do
    scan_regex(rest, line + 1, 1, in_class, [?\n | acc])
  end

  defp scan_regex(<<c::utf8, rest::binary>>, line, col, in_class, acc) do
    scan_regex(rest, line, col + 1, in_class, [c | acc])
  end

  defp scan_regex(<<>>, line, col, _in_class, _acc) do
    {:error, "unterminated regex literal", line, col}
  end
end
