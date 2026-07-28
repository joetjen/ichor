defmodule IchorRuntime.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ichor_runtime,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "IchorRuntime",
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp description do
    "The small runtime support library Ichor-generated parsers (mix ichor.gen, or " <>
      "use Ichor) call into -- capture dispatch, error formatting, the compiled " <>
      "Tokenizer/Parser combinators, and the LR/GLR shift-reduce/GSS runtime. " <>
      "Ichor itself (grammar parsing, analysis, and codegen) is a dev-time-only " <>
      "dependency; this is the only piece a generated parser needs at runtime."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/joetjen/ichor"},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/ichor",
      source_ref: "v#{@version}",
      extras: ["README.md"],
      groups_for_modules: groups_for_modules()
    ]
  end

  defp groups_for_modules do
    [
      "Capture Dispatch": [
        Ichor.Actions,
        Ichor.Capture,
        Ichor.Node,
        Ichor.CustomLexeme,
        Ichor.CustomRule
      ],
      Errors: [
        Ichor.Error
      ],
      "Lexing/Parsing Support": [
        Grammar.VM.Token,
        Grammar.Source,
        Grammar.Lexer,
        Grammar.Native.Runtime.Parser,
        Grammar.Native.Runtime.Tokenizer
      ],
      "LR/GLR Runtime": [
        Grammar.LRTable,
        Grammar.LRTable.Production,
        Grammar.LRTable.Captures,
        Grammar.LR.Stack,
        Grammar.GLR.GSS,
        Grammar.GLR.Runtime
      ],
      Toolkit: [
        Ichor.Toolkit.Result
      ]
    ]
  end
end
