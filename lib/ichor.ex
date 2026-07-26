defmodule Ichor do
  @moduledoc """
  Ichor reads grammar definitions -- its own language Aether, plus ABNF,
  BNF, EBNF, and PEG importers -- and turns each one into a working
  Lexer + Parser + Executor for whatever language the grammar describes,
  via either an interpreted VM backend (`Grammar.VM`) or compile-time
  native codegen (`__using__/1` below).

  This top-level module holds `evaluate_node/3`: a general entry point for
  evaluating a `Ichor.Capture.node_t()` that didn't come from the original
  parse. Every other `.eval` thunk a `Ichor.Actions` implementation sees
  is tied to a specific position in the text that was actually parsed; a
  macro's *expansion* isn't -- it's new code, built by the macro body,
  that still needs to go through the same `handle_rule`/`handle_token`
  dispatch (or default fallback) as anything else. Not Lisp-specific in
  principle: any grammar with macro-like features would need this same
  re-entry point.

  It also holds `__using__/1`, the native codegen backend's own entry
  point:

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
  module, via `Grammar.Native.generate/2`.
  """

  alias Ichor.Actions

  @doc """
  Evaluates a raw capture node (as found on any `Ichor.Capture.node`, or
  built directly by something like a macro's `unreify`) against
  `actions_module`, starting from `context`.
  """
  @spec evaluate_node(Ichor.Capture.node_t(), module(), Actions.context()) ::
          {:ok, term(), Actions.context()} | {:error, Ichor.Error.t()}
  def evaluate_node({:token, name, text}, actions_module, context) do
    with {:ok, value} <- Actions.dispatch_token(actions_module, name, text, context) do
      {:ok, value, context}
    end
  end

  def evaluate_node({:rule, name, raw_captures}, actions_module, context) do
    Actions.dispatch_rule(actions_module, name, raw_captures, context, %{})
  end

  def evaluate_node({:text, text}, _actions_module, context) do
    {:ok, text, context}
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

    grammar = parse_and_analyze!(source, file)
    body = Grammar.Native.generate(grammar, actions_module)

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
