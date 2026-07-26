defmodule Support.ExampleGrammars do
  @moduledoc """
  The nine worked-example grammars used throughout this test suite,
  shared between `Aether.ParserTest` and `Grammar.AnalysisTest` so both
  suites exercise the exact same fixtures without duplicating them.

  Calculator stays inline here since it's small and this module's own
  primary reason to exist; the other eight live as real `.aether` files
  next to the test directory that most directly exercises each one
  (`test/lisp/lisp.aether`, `test/yaml/yaml.aether`, etc.) and are read
  from disk at compile time -- `@external_resource` per file so editing
  a `.aether` fixture triggers recompilation the same way editing this
  module itself would.
  """

  @external_resource Path.expand("../lisp/lisp.aether", __DIR__)
  @external_resource Path.expand("../yaml/yaml.aether", __DIR__)
  @external_resource Path.expand("../logql/logql.aether", __DIR__)
  @external_resource Path.expand("../sql/sql.aether", __DIR__)
  @external_resource Path.expand("../http/http.aether", __DIR__)
  @external_resource Path.expand("../regex/regex.aether", __DIR__)
  @external_resource Path.expand("../forth/forth.aether", __DIR__)
  @external_resource Path.expand("../markdown/markdown.aether", __DIR__)

  @lisp File.read!(Path.expand("../lisp/lisp.aether", __DIR__))
  @yaml File.read!(Path.expand("../yaml/yaml.aether", __DIR__))
  @logql File.read!(Path.expand("../logql/logql.aether", __DIR__))
  @sql File.read!(Path.expand("../sql/sql.aether", __DIR__))
  @http File.read!(Path.expand("../http/http.aether", __DIR__))
  @regex File.read!(Path.expand("../regex/regex.aether", __DIR__))
  @forth File.read!(Path.expand("../forth/forth.aether", __DIR__))
  @markdown File.read!(Path.expand("../markdown/markdown.aether", __DIR__))

  @doc "A map of example name (e.g. \"4.1 calculator\") to its `.aether` source."
  @spec all() :: %{String.t() => String.t()}
  def all do
    %{
      "4.1 calculator" => ~S"""
      @grammar "calculator"
      @root expr

      NUMBER := /\d+(\.\d+)?/
      SPACE  := [ \t\n]+

      expr   := term (op:("+" | "-") term)*
      term   := factor (op:("*" | "/") factor)*
      factor := NUMBER | "(" expr ")"
      """,
      "4.2 lisp" => @lisp,
      "4.3 yaml" => @yaml,
      "4.4 logql" => @logql,
      "4.5 sql" => @sql,
      "4.6 http" => @http,
      "4.7 regex" => @regex,
      "4.8 forth" => @forth,
      "4.9 markdown" => @markdown
    }
  end
end
