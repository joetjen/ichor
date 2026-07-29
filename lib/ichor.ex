defmodule Ichor do
  @moduledoc """
  Ichor reads grammar definitions -- its own language Aether, plus ABNF,
  BNF, EBNF, and PEG importers -- and turns each one into a working
  Lexer + Parser + Executor for whatever language the grammar describes,
  via either an interpreted VM backend (`Grammar.VM`) or compile-time
  native codegen (`__using__/1` below).

  This top-level module holds `__using__/1`, the native codegen
  backend's own entry point:

      defmodule Calculator do
        use Ichor, grammar: "calculator.aether", actions: Calculator.Actions
      end

      Calculator.run("2 + 3 * 4")  #=> {:ok, 14}

  `grammar:` is a path to a `.aether` file, resolved relative to the
  `use`-ing module's own source file (so a grammar file can live
  alongside the module that compiles it); `grammar_source:` takes
  literal grammar text directly instead, for callers that don't want a
  separate file on disk. Exactly one of the two is required. `actions:`
  bakes in a compile-time-known module reference -- `parse/1`,
  `tokenize/1`, and `run/1,2` all get added directly to the `use`-ing
  module, via `generate/3` below (dispatching further to
  `Grammar.Native`/`Grammar.Native.LR`/`Grammar.Native.GLR` by
  `@engine`).

  `generate/3` is also `Mix.Tasks.Ichor.Gen`'s entry point: the same
  parse-analyze-codegen pipeline, just called from a Mix task instead of
  from macro expansion, so a grammar can be compiled to a plain,
  ordinary `.ex` file once and checked in, instead of every `use Ichor`
  caller re-parsing and re-analyzing the same grammar on every compile.

  A grammar-with-macros implementation (anything needing to evaluate a
  raw capture node that didn't come from the original parse -- LISP's
  own `defmacro`/expansion, most notably) wants `Ichor.Actions.evaluate_node/3`,
  not anything here: unlike `generate/3`/`__using__/1`, which are
  genuinely compile-time-only, that's a runtime entry point, and lives
  in `ichor_runtime` alongside the rest of `Ichor.Actions`.
  """

  @doc """
  Parses and analyzes `source` (a full `.aether` grammar), then
  generates the quoted module body for `actions_module` -- whichever of
  `Grammar.Native`, `Grammar.Native.LR`, or `Grammar.Native.GLR` the
  grammar's own `@engine` pragma selects. `file` is used only for
  error messages (line/column context); pass `nil` if `source` didn't
  come from a file.

  Shared by `__using__/1` (which splices the result straight into the
  caller's module) and `Mix.Tasks.Ichor.Gen` (which wraps it in its own
  `defmodule` and writes it to disk as ordinary source).

  Raises `CompileError` if `source` fails to parse or fails analysis
  (unresolved rule references, a non-`peg` engine picked for a grammar
  Analysis flags, an LR/GLR grammar with unresolvable conflicts, etc.).
  """
  @spec generate(String.t(), String.t() | nil, module()) :: Macro.t()
  def generate(source, file, actions_module) do
    grammar = parse_and_analyze!(source, file)

    case grammar.engine do
      :peg -> Grammar.Native.generate(grammar, actions_module)
      :lr -> Grammar.Native.LR.generate(grammar, actions_module)
      :glr -> Grammar.Native.GLR.generate(grammar, actions_module)
    end
  end

  @doc false
  defmacro __using__(opts) do
    file = eval_opt(opts, :grammar, __CALLER__)
    source_opt = eval_opt(opts, :grammar_source, __CALLER__)
    actions_ast = Keyword.fetch!(opts, :actions)
    actions_module = Macro.expand(actions_ast, __CALLER__)

    {source, external_resource} =
      case {file, source_opt} do
        {nil, nil} ->
          raise ArgumentError,
                "use Ichor requires either grammar: (a file path) or grammar_source: (inline text)"

        {file, nil} when is_binary(file) ->
          path = Path.join(Path.dirname(__CALLER__.file), file)
          {File.read!(path), path}

        {nil, source} when is_binary(source) ->
          {source, nil}

        _ ->
          raise ArgumentError,
                "use Ichor accepts exactly one of grammar: or grammar_source:, not both"
      end

    body = generate(source, file, actions_module)

    resource_attr =
      if external_resource do
        quote do
          @external_resource unquote(external_resource)
        end
      end

    quote do
      unquote(resource_attr)
      unquote(body)
    end
  end

  # `opts` are unevaluated AST at macro-expansion time (e.g. a module
  # attribute or a string-concat expression passed as `grammar:`), so the
  # value has to be evaluated in the caller's own environment before it's
  # usable as a plain Elixir term.
  defp eval_opt(opts, key, env) do
    case Keyword.fetch(opts, key) do
      {:ok, ast} ->
        {value, _bindings} = Code.eval_quoted(ast, [], env)
        value

      :error ->
        nil
    end
  end

  defp parse_and_analyze!(source, file) do
    with {:ok, grammar} <- Aether.Parser.parse(source, file),
         {:ok, grammar} <- Grammar.Analysis.run(grammar) do
      grammar
    else
      {:error, errors} when is_list(errors) ->
        raise CompileError, description: Enum.map_join(errors, "\n", &Ichor.Error.format/1)

      {:error, error} ->
        raise CompileError, description: Ichor.Error.format(error)
    end
  end
end
