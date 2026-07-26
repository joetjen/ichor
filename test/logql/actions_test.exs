defmodule LogQL.ActionsTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.4 logql"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  @streams [
    %{
      labels: %{"app" => "ichor", "env" => "prod"},
      lines: ["error: boom", "info: ok", "error: fire"]
    },
    %{labels: %{"app" => "other", "env" => "prod"}, lines: ["error: nope"]}
  ]

  setup do
    {:ok, grammar: grammar(), ctx: %{streams: @streams}}
  end

  defp run(grammar, ctx, source), do: Grammar.VM.run(grammar, source, LogQL.Actions, ctx)

  describe "the logql worked example" do
    test "stream selector plus a filter_expr and a logfmt stage", %{grammar: g, ctx: ctx} do
      assert {:ok, ["error: boom", "error: fire"]} =
               run(g, ctx, ~S({app="ichor"} |= "error" | logfmt))
    end
  end

  describe "stream selection" do
    test "an equality matcher selects only the matching stream", %{grammar: g, ctx: ctx} do
      assert {:ok, ["error: boom", "info: ok", "error: fire"]} = run(g, ctx, ~S({app="ichor"}))
    end

    test "a regex matcher (=~)", %{grammar: g, ctx: ctx} do
      assert {:ok, lines} = run(g, ctx, ~S({app=~"ic.*"}))
      assert length(lines) == 3
    end

    test "multiple label matchers narrow the stream selection", %{grammar: g, ctx: ctx} do
      assert {:ok, ["error: nope"]} = run(g, ctx, ~S({app="other", env="prod"}))
    end

    test "no matching stream yields no lines", %{grammar: g, ctx: ctx} do
      assert {:ok, []} = run(g, ctx, ~S({app="missing"}))
    end
  end

  describe "filter_expr operators (grammar fixed to match real LogQL syntax -- see LogQL.Actions moduledoc)" do
    test "|= keeps lines containing the substring", %{grammar: g, ctx: ctx} do
      assert {:ok, ["error: boom", "error: fire"]} = run(g, ctx, ~S({app="ichor"} |= "error"))
    end

    test "!= drops lines containing the substring", %{grammar: g, ctx: ctx} do
      assert {:ok, ["info: ok"]} = run(g, ctx, ~S({app="ichor"} != "error"))
    end

    test "|~ keeps lines matching the regex", %{grammar: g, ctx: ctx} do
      assert {:ok, ["error: boom", "error: fire"]} = run(g, ctx, ~S({app="ichor"} |~ "err.*"))
    end

    test "!~ drops lines matching the regex", %{grammar: g, ctx: ctx} do
      assert {:ok, ["info: ok"]} = run(g, ctx, ~S({app="ichor"} !~ "err.*"))
    end
  end

  describe "chained pipeline stages" do
    test "a filter followed by line_format", %{grammar: g, ctx: ctx} do
      assert {:ok, ["<redacted>", "<redacted>"]} =
               run(g, ctx, ~S({app="ichor"} |= "error" | line_format "<redacted>"))
    end
  end
end
