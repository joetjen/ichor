defmodule Ichor.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ichor,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "Ichor",
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Compiles grammar definitions -- Aether, its own DSL, plus ABNF/EBNF/PEG/BNF " <>
      "importers -- into separated Lexer/Parser/Analysis/Executor modules, with " <>
      "both an interpreted VM backend and a compile-time native codegen backend."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/joetjen/ichor"},
      files: ~w(lib priv/grammar .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/ichor",
      source_ref: "v#{@version}",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules()
    ]
  end

  defp extras do
    [
      "README.md",
      "guides/TUTORIAL.md",
      "guides/EXAMPLES.md",
      "guides/CHEATSHEET.md",
      "guides/aether/TUTORIAL.md",
      "guides/aether/AETHER.md",
      "guides/aether/AETHER_EXAMPLES.md",
      "guides/aether/AETHER_CHEATSHEET.md",
      "CHANGELOG.md",
      "CONTRIBUTION.md",
      "LICENSE"
    ]
  end

  defp groups_for_extras do
    [
      Aether: Path.wildcard("guides/aether/*.md")
    ]
  end

  defp groups_for_modules do
    [
      Core: [
        Ichor,
        Ichor.Actions,
        Ichor.Capture,
        Ichor.Node,
        Ichor.Error
      ],
      "Grammar IR": [
        Grammar.IR,
        Grammar.IR.AndPred,
        Grammar.IR.Any,
        Grammar.IR.Capture,
        Grammar.IR.CharClass,
        Grammar.IR.Choice,
        Grammar.IR.Indent,
        Grammar.IR.Literal,
        Grammar.IR.Meta,
        Grammar.IR.NotPred,
        Grammar.IR.Opt,
        Grammar.IR.Plus,
        Grammar.IR.Rep,
        Grammar.IR.RuleRef,
        Grammar.IR.Seq,
        Grammar.IR.Star
      ],
      "Aether Front-end": [
        Aether.Grammar,
        Aether.Lexer,
        Aether.Parser,
        Aether.Token
      ],
      Analysis: [
        Grammar.Analysis
      ],
      "VM Backend": [
        Grammar.VM,
        Grammar.VM.CharCompiler,
        Grammar.VM.CharInterpreter,
        Grammar.VM.Compiler,
        Grammar.VM.Lexer,
        Grammar.VM.Linker,
        Grammar.VM.Program,
        Grammar.VM.RuleCompiler,
        Grammar.VM.Token,
        Grammar.VM.TokenInterpreter
      ],
      "Native Backend": [
        Grammar.Native,
        Grammar.Native.CharCompiler,
        Grammar.Native.RuleCompiler,
        Grammar.Native.Runtime
      ],
      Tooling: [
        Grammar.Tokens,
        Mix.Tasks.Ichor.Tokens
      ],
      "Format Importers": [
        Ichor.ABNF,
        Ichor.ABNF.Actions,
        Ichor.BNF,
        Ichor.BNF.Actions,
        Ichor.EBNF.ISO,
        Ichor.EBNF.ISO.Actions,
        Ichor.EBNF.W3C,
        Ichor.EBNF.W3C.Actions,
        Ichor.PEG,
        Ichor.PEG.Actions
      ]
    ]
  end
end
