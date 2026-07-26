defmodule Grammar.Native.LogQLTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp vm_grammar do
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
    {:ok, grammar: vm_grammar(), ctx: %{streams: @streams}}
  end

  describe "run/2 parity with the VM backend" do
    for source <- [
          ~S({app="ichor"} |= "error" | logfmt),
          ~S({app="ichor"}),
          ~S({app=~"ic.*"}),
          ~S({app="other", env="prod"}),
          ~S({app="missing"}),
          ~S({app="ichor"} != "error"),
          ~S({app="ichor"} |~ "err.*"),
          ~S({app="ichor"} !~ "err.*"),
          ~S({app="ichor"} |= "error" | line_format "<redacted>")
        ] do
      test "#{inspect(source)}", %{grammar: g, ctx: ctx} do
        source = unquote(source)
        assert Native.LogQL.run(source, ctx) == Grammar.VM.run(g, source, LogQL.Actions, ctx)
      end
    end
  end
end
