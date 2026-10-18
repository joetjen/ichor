defmodule Ichor.Conformance do
  @moduledoc """
  This implementation's answers to the Ichor Conformance Suite,
  through either backend.

  The suite runs every Ichor implementation against the same
  grammars and inputs, reaching each one through an adapter
  (`mix ichor.conformance` here) with a JSON request, and reading a JSON
  answer back:

      %{"cases" => [%{"id" => "trees: one number", "operation" => "parse",
                      "grammar" => "/abs/calculator.aether", "text" => "2"}]}
      #=> %{"results" => [%{"id" => "trees: one number", "tree" => ...}]}

  **A grammar may be written in any notation Ichor reads** -- Aether,
  ABNF, BNF, ISO EBNF, PEG -- told by its extension or an `@style` line,
  exactly as `mix ichor.gen` tells it (`Ichor.GrammarImport.styled/2`).
  What the suite compares is the parse, so the same language written
  twice must come to the same tree.

  **It lives here, not in `ichor_runtime`**, because the runtime is only
  ever called by generated code: to answer a case, a parser has to be
  made from the case's grammar first, and making one is Ichor's.

  **The backend is the implementation.** `:interpreted` runs the
  grammar through `Grammar.VM`, `Grammar.LR` or `Grammar.GLR`, by its
  engine; `:compiled` generates a module with `Ichor.generate_from_grammar/2`
  and runs that. The suite configures each as an implementation of its
  own, which is what checks that the two agree.

  A `"tokens"` answers `"tokens"`, the grammar's token stream for the
  text -- every token in order, trivia included, `@keywords` applied, as
  `{name, text, line, column}`, an inline literal's token named nil --
  or `"error"`, the lexer error's stage, line and column.

  A `"parse"` answers one of:

  - `"tree"` -- the default tree, what the parse comes to with no
    actions of its own: a token is its text, a rule with exactly one
    capture matched once is that capture's value, and any other rule is
    `{:node, rule, captures}`, its captures a map from name to value;
  - `"error"` -- `%{stage: ..., line: ..., column: ...}` of the first
    error, from reading the grammar, analysing it, or parsing the text.

  Both travel as the suite's typed JSON (`{"keyword": "node"}`,
  `{"integer": "1"}`, `{"tuple": [...]}`, `{"map": [[k, v], ...]}`), so
  nothing tells two values apart differently here than in Praxis.
  """

  @typedoc "Which of this implementation's two backends answers."
  @type backend :: :interpreted | :compiled

  defmodule NoActions do
    @moduledoc """
    An actions module answering for nothing, so every rule and token
    falls to `Ichor.Actions`'s defaults: what the suite compares is the
    default tree.
    """
    @behaviour Ichor.Actions
  end

  @doc "The answer to `request` through `backend`, one result per case, in order."
  @spec answer(map(), backend()) :: map()
  def answer(%{"cases" => cases}, backend)
      when is_list(cases) and backend in [:interpreted, :compiled] do
    {results, _parsers} =
      Enum.map_reduce(cases, %{}, fn c, parsers -> result(c, backend, parsers) end)

    %{"results" => results}
  end

  # One case's result, and the parsers made so far. A grammar is made
  # into a parser once per batch, however many cases parse with it:
  # generating and loading a module per case would cost the compiled
  # backend most of its run.
  defp result(
         %{"id" => id, "operation" => "parse", "grammar" => path, "text" => text},
         backend,
         parsers
       ) do
    {parser, parsers} = parser(path, backend, parsers)

    outcome =
      with {:ok, made} <- parser,
           {:ok, value} <- made.run.(text) do
        %{"tree" => encode(tree(value))}
      else
        {:error, error} -> %{"error" => encode(failure(error))}
      end

    {Map.put(outcome, "id", id), parsers}
  end

  defp result(
         %{"id" => id, "operation" => "tokens", "grammar" => path, "text" => text},
         backend,
         parsers
       ) do
    {parser, parsers} = parser(path, backend, parsers)

    outcome =
      with {:ok, made} <- parser,
           {:ok, tokens} <- made.tokenize.(text) do
        %{"tokens" => encode(Enum.map(tokens, &token(&1, made.anonymous)))}
      else
        {:error, error} -> %{"error" => encode(failure(error))}
      end

    {Map.put(outcome, "id", id), parsers}
  end

  defp result(%{"id" => id, "operation" => operation}, _backend, parsers),
    do: {%{"id" => id, "error" => "unsupported operation #{inspect(operation)}"}, parsers}

  defp parser(path, backend, parsers) do
    case Map.fetch(parsers, path) do
      {:ok, parser} ->
        {parser, parsers}

      :error ->
        parser = made(path, backend)
        {parser, Map.put(parsers, path, parser)}
    end
  end

  # The grammar at `path` as a function from text to `{:ok, value}` or
  # `{:error, error}`. Analysis runs first for both backends, so a
  # grammar that does not analyse is the same error from either; the
  # compiled one then generates from the grammar as read, since
  # `generate_from_grammar/2` analyses it again itself.
  defp made(path, backend) do
    with {:ok, style, source} <- Ichor.GrammarImport.styled(File.read!(path), path),
         {:ok, grammar} <- read(style, source, path),
         {:ok, analysed} <- Grammar.Analysis.run(grammar) do
      {:ok, Map.put(runner(backend, grammar, analysed), :anonymous, analysed.anon_tokens)}
    end
  end

  # A grammar in any notation Ichor reads, as the grammar it means:
  # Aether by its own reader, anything else by its importer, the way
  # `mix ichor.gen` reads one (`Ichor.GrammarImport.styled/2`).
  defp read(:aether, source, path), do: Aether.Parser.parse(source, path)
  defp read(style, source, _path), do: Ichor.GrammarImport.import_grammar(style, source)

  defp runner(:interpreted, _grammar, analysed) do
    engine =
      case analysed.engine do
        :peg -> Grammar.VM
        :lr -> Grammar.LR
        :glr -> Grammar.GLR
      end

    %{
      run: fn text -> engine.run(analysed, text, NoActions) end,
      tokenize: fn text -> Grammar.VM.tokenize(analysed, text) end
    }
  end

  defp runner(:compiled, grammar, _analysed) do
    module = Module.concat(__MODULE__, "Parser#{System.unique_integer([:positive])}")

    Module.create(
      module,
      Ichor.generate_from_grammar(grammar, NoActions),
      Macro.Env.location(__ENV__)
    )

    %{run: fn text -> module.run(text) end, tokenize: fn text -> module.tokenize(text, nil) end}
  end

  # A token as the suite writes it, `{name, text, line, column}`. An
  # inline literal's token has no name its author chose -- `ANON_1` is
  # generated -- so its name is nil, and it is known by its text.
  defp token(%Grammar.VM.Token{name: name, text: text, line: line, column: column}, anonymous) do
    {if(MapSet.member?(anonymous, name), do: nil, else: name), text, line, column}
  end

  # A value as the suite writes it: a node as a tagged tuple, without
  # the span, which the default tree never sets.
  defp tree(%Ichor.Node{rule: rule, captures: captures}),
    do: {:node, rule, Map.new(captures, fn {name, value} -> {name, tree(value)} end)}

  defp tree(list) when is_list(list), do: Enum.map(list, &tree/1)
  defp tree(other), do: other

  defp failure([error | _]), do: failure(error)

  defp failure(%Ichor.Error{stage: stage, line: line, column: column}),
    do: %{stage: stage, line: line, column: column}

  # The suite's typed JSON, from `assize`'s EXAMPLES.md.
  defp encode(v) when is_nil(v) or is_boolean(v) or is_binary(v), do: v
  defp encode(n) when is_integer(n), do: %{"integer" => Integer.to_string(n)}
  defp encode(f) when is_float(f), do: %{"float" => Float.to_string(f)}
  defp encode(a) when is_atom(a), do: %{"keyword" => Atom.to_string(a)}
  defp encode(t) when is_tuple(t), do: %{"tuple" => t |> Tuple.to_list() |> Enum.map(&encode/1)}
  defp encode(list) when is_list(list), do: Enum.map(list, &encode/1)
  defp encode(%{} = map), do: %{"map" => Enum.map(map, fn {k, v} -> [encode(k), encode(v)] end)}
end
