defmodule Grammar.ActionErrorPositionsTest do
  @moduledoc """
  An action's error says where, and every capture knows where it
  matched -- by every engine and both backends, lossless or not
  (`Ichor.Actions`' "An action's error says where",
  `Ichor.Capture`'s `span`).
  """

  use ExUnit.Case, async: true

  defmodule PairActions do
    @moduledoc "Refuses a float key and the value 13; answers an entry's captures' spans."
    @behaviour Ichor.Actions

    alias Ichor.Error

    @impl true
    def handle_rule(:entry, %{key: %{node: {:token, :FLOAT, _}}}, _ctx),
      do: {:error, Error.new(message: "a float can't be a key", stage: :action, data: :float_key)}

    def handle_rule(:entry, %{key: key, value: value}, ctx) do
      with {:ok, _value, ctx} <- value.eval.(ctx) do
        {:ok, {key.span, value.span}, ctx}
      end
    end

    @impl true
    def handle_token(:INT, "13", _ctx),
      do: {:error, Error.new(message: "unlucky", stage: :action)}
  end

  @body ~S"""
  @skip WS
  WS    := [ \t\n]+
  IDENT := [a-z]+
  FLOAT := [0-9]+ "." [0-9]+
  INT   := [0-9]+
  doc   := entry+
  entry := key:IDENT "=" value:INT | key:FLOAT "=" value:INT
  """

  defp source(engine, root) do
    engine_line = if engine == :peg, do: "", else: "@engine #{engine}\n"
    "@grammar \"pairs\"\n@root #{root}\n" <> engine_line <> @body
  end

  defp grammar(engine, root) do
    {:ok, grammar} = Aether.Parser.parse(source(engine, root), nil)
    grammar
  end

  defp interpreted(engine), do: %{peg: Grammar.VM, lr: Grammar.LR, glr: Grammar.GLR}[engine]

  defp compiled(engine, root, actions, lossless) do
    name = Module.concat(__MODULE__, "P#{System.unique_integer([:positive])}")
    code = Ichor.generate_from_grammar(grammar(engine, root), actions, lossless: lossless)
    Module.create(name, code, __ENV__)
    name
  end

  # `input` through `engine`'s grammar rooted at `root`, by `backend`,
  # with `actions`; the lossless run answers its value as the ordinary
  # one does, so both are compared alike.
  defp run(engine, backend, mode, input, root \\ :doc, actions \\ PairActions)

  defp run(engine, :interpreted, :ordinary, input, root, actions) do
    {:ok, analysed} = Grammar.Analysis.run(grammar(engine, root))
    interpreted(engine).run(analysed, input, actions)
  end

  defp run(engine, :interpreted, :lossless, input, root, actions) do
    {:ok, analysed} = Grammar.Analysis.run(grammar(engine, root))
    value_of(interpreted(engine).run_lossless(analysed, input, actions))
  end

  defp run(engine, :compiled, :ordinary, input, root, actions),
    do: compiled(engine, root, actions, false).run(input)

  defp run(engine, :compiled, :lossless, input, root, actions),
    do: value_of(compiled(engine, root, actions, true).run_lossless(input))

  defp value_of({:ok, value, _tree}), do: {:ok, value}
  defp value_of(error), do: error

  defp place({:error, [error | _]}), do: place({:error, error})
  defp place({:error, error}), do: {error.stage, error.line, error.column}

  for engine <- [:peg, :lr, :glr],
      backend <- [:interpreted, :compiled],
      mode <- [:ordinary, :lossless] do
    describe "#{engine}, #{backend}, #{mode}" do
      test "places a rule's refusal where the rule matched" do
        result = run(unquote(engine), unquote(backend), unquote(mode), "a = 1\n 1.5 = 2")
        assert place(result) == {:action, 2, 2}
      end

      test "shows a rule's refusal with its line and a caret, keeping the rest" do
        assert {:error, error} =
                 run(unquote(engine), unquote(backend), unquote(mode), "a = 1\n 1.5 = 2")

        error = if is_list(error), do: hd(error), else: error
        assert error.context_lines == "2 |  1.5 = 2\n  |  ^"
        assert {error.message, error.data} == {"a float can't be a key", :float_key}
      end

      test "places a token's refusal where the token matched" do
        result = run(unquote(engine), unquote(backend), unquote(mode), "a = 1\n b = 13")
        assert place(result) == {:action, 2, 6}
      end

      test "gives every capture the span it matched" do
        assert run(unquote(engine), unquote(backend), unquote(mode), "\n  bc = 23 ", :entry) ==
                 {:ok, {{2, 3, 2}, {2, 8, 2}}}
      end

      test "gives the default node the span its rule matched" do
        assert {:ok, %Ichor.Node{rule: :entry, span: {2, 3, 7}}} =
                 run(
                   unquote(engine),
                   unquote(backend),
                   unquote(mode),
                   "\n  bc = 23 ",
                   :entry,
                   Support.NoActions
                 )
      end
    end
  end

  describe "a sequence of top-level matches" do
    test "places a refusal in a later match where it matched, interpreted" do
      {:ok, analysed} = Grammar.Analysis.run(grammar(:peg, :entry))
      result = Grammar.VM.run_sequence(analysed, "a = 1\n 1.5 = 2", PairActions, nil)
      assert place(result) == {:action, 2, 2}
    end

    test "places a refusal in a later match where it matched, compiled" do
      module = compiled(:peg, :entry, PairActions, false)
      assert place(module.run_sequence("a = 1\n 1.5 = 2", nil)) == {:action, 2, 2}
    end

    test "gives each match's captures their spans, interpreted" do
      {:ok, analysed} = Grammar.Analysis.run(grammar(:peg, :entry))

      assert Grammar.VM.run_sequence(analysed, "a = 1\n bc = 23", PairActions, nil) ==
               {:ok, [{{1, 1, 1}, {1, 5, 1}}, {{2, 2, 2}, {2, 7, 2}}], nil}
    end

    test "gives each match's captures their spans, compiled" do
      module = compiled(:peg, :entry, PairActions, false)

      assert module.run_sequence("a = 1\n bc = 23", nil) ==
               {:ok, [{{1, 1, 1}, {1, 5, 1}}, {{2, 2, 2}, {2, 7, 2}}], nil}
    end
  end
end
