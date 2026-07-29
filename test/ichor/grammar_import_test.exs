defmodule Ichor.GrammarImportTest do
  use ExUnit.Case, async: true

  alias Grammar.IR
  alias Ichor.GrammarImport

  defmodule NoActs do
    @behaviour Ichor.Actions
  end

  defp compile_and_run!(style, source, input, opts \\ []) do
    {:ok, grammar} = GrammarImport.import_grammar(style, source, opts)
    body = Ichor.generate_from_grammar(grammar, NoActs)
    mod = Module.concat([:"GrammarImportTest#{System.unique_integer([:positive])}"])
    Module.create(mod, body, Macro.Env.location(__ENV__))
    {grammar, mod.parse(input)}
  end

  describe "import_grammar/3: root selection" do
    test "defaults to the source's own first-declared rule" do
      source = "num <- digit+\ndigit <- [0-9]\n"
      assert {:ok, grammar} = GrammarImport.import_grammar(:peg, source)
      assert grammar.root == :num
    end

    test "an explicit :root overrides the first-declared rule" do
      source = "num <- digit+\ndigit <- [0-9]\n"
      assert {:ok, grammar} = GrammarImport.import_grammar(:peg, source, root: :digit)
      assert grammar.root == :digit
    end

    test "declares-no-rules is a real error, not a crash, when no root is available at all" do
      # ABNF's own `rulelist := (rule | blank_line)+` parses a
      # blank-line-only source just fine -- it's the *ruleset* that ends
      # up empty, not the parse itself (unlike PEG/BNF/ISO EBNF, whose
      # grammars require at least one rule to parse at all).
      assert {:error, error} = GrammarImport.import_grammar(:abnf, "\r\n")
      assert error.message =~ "declares no rules"
    end

    test "an explicit :root naming a rule the source doesn't declare is a real error" do
      source = "num <- digit+\ndigit <- [0-9]\n"
      assert {:error, error} = GrammarImport.import_grammar(:peg, source, root: :nonexistent)
      assert error.message =~ "nonexistent"
    end
  end

  describe "import_grammar/3: root order per format" do
    test "ABNF" do
      source = "second = DIGIT\r\nfirst = ALPHA\r\n"
      assert {:ok, grammar} = GrammarImport.import_grammar(:abnf, source)
      assert grammar.root == :second
    end

    test "BNF" do
      source = "<second> ::= '0'\n<first> ::= '1'\n"
      assert {:ok, grammar} = GrammarImport.import_grammar(:bnf, source)
      assert grammar.root == :second
    end

    test "ISO EBNF" do
      source = "second = '0' ;\nfirst = '1' ;\n"
      assert {:ok, grammar} = GrammarImport.import_grammar(:ebnf_iso, source)
      assert grammar.root == :second
    end

    test "PEG" do
      source = "second <- '0'\nfirst <- '1'\n"
      assert {:ok, grammar} = GrammarImport.import_grammar(:peg, source)
      assert grammar.root == :second
    end
  end

  describe "import_grammar/3: assembled grammar shape" do
    test "always @noskip (skip: nil)" do
      assert {:ok, grammar} = GrammarImport.import_grammar(:peg, "a <- 'x'\n")
      assert grammar.skip == nil
    end

    test "bare literals inside a rule are auto-promoted into synthetic tokens" do
      assert {:ok, grammar} = GrammarImport.import_grammar(:peg, "a <- 'x' 'y'\n")
      assert %IR.Seq{exprs: [%IR.RuleRef{}, %IR.RuleRef{}]} = grammar.rules[:a]
      assert map_size(grammar.tokens) == 2
    end
  end

  describe "import_grammar/3: end-to-end parsing" do
    test "ABNF" do
      {_grammar, result} = compile_and_run!(:abnf, "ip4octet = 1*3DIGIT\r\n", "255")
      assert {:ok, 3, _captures} = result
    end

    test "ABNF rejects input its own repetition bound disallows" do
      {_grammar, result} = compile_and_run!(:abnf, "ip4octet = 1*3DIGIT\r\n", "2555")
      assert {:error, _error} = result
    end

    test "BNF (right-recursive)" do
      source =
        "<num> ::= <digit> <num> | <digit>\n<digit> ::= '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9'\n"

      {_grammar, result} = compile_and_run!(:bnf, source, "123")
      assert {:ok, 3, _captures} = result
    end

    test "ISO EBNF" do
      source =
        "num = digit, { digit } ;\ndigit = '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' ;\n"

      {_grammar, result} = compile_and_run!(:ebnf_iso, source, "42")
      assert {:ok, 2, _captures} = result
    end

    test "PEG" do
      {_grammar, result} = compile_and_run!(:peg, "num <- digit+\ndigit <- [0-9]\n", "999")
      assert {:ok, 3, _captures} = result
    end
  end

  describe "ABNF core rules (RFC 5234 Appendix B)" do
    test "a core rule referenced but never defined is filled in automatically" do
      assert {:ok, grammar} = GrammarImport.import_grammar(:abnf, "octet = DIGIT\r\n")
      assert Map.has_key?(grammar.rules, :digit)
    end

    test "only the transitive closure of referenced core rules is merged, not all sixteen" do
      # CRLF references CR and LF; nothing here ever mentions the other
      # twelve (ALPHA, DIGIT, HEXDIG, VCHAR, ...) at all.
      assert {:ok, grammar} = GrammarImport.import_grammar(:abnf, "line = CRLF\r\n")
      assert Map.keys(grammar.rules) |> Enum.sort() == [:cr, :crlf, :lf, :line]
    end

    test "transitively-referenced core rules (LWSP -> WSP/CRLF -> CR/LF/SP/HTAB) are all pulled in" do
      assert {:ok, grammar} = GrammarImport.import_grammar(:abnf, "x = LWSP\r\n")

      assert Enum.all?(
               [:cr, :lf, :crlf, :sp, :htab, :wsp, :lwsp, :x],
               &Map.has_key?(grammar.rules, &1)
             )
    end

    test "the source's own definition of a core rule name overrides the built-in one" do
      # A source that defines its own (nonstandard) DIGIT shouldn't have
      # it silently replaced by the RFC 5234 default.
      source = "octet = DIGIT\r\nDIGIT = \"9\"\r\n"
      assert {:ok, _grammar} = GrammarImport.import_grammar(:abnf, source)

      {_grammar, result} = compile_and_run!(:abnf, source, "9")
      assert {:ok, 1, _captures} = result
      {_grammar, result2} = compile_and_run!(:abnf, source, "5")
      assert {:error, _} = result2
    end

    test "non-ABNF styles never get core rules merged in -- a dangling reference stays dangling" do
      # import_grammar/3 itself doesn't validate references (Grammar.Analysis
      # does, later) -- the point here is just that no :digit rule gets
      # silently added for a style the core-rules prelude doesn't apply to.
      assert {:ok, grammar} = GrammarImport.import_grammar(:peg, "octet <- DIGIT\n")
      assert Map.keys(grammar.rules) == [:octet]
      refute Map.has_key?(grammar.rules, :digit)
    end
  end

  describe "ABNF line-ending normalization" do
    test "bare \\n line endings work, not just literal \\r\\n" do
      source = "ip4octet = 1*3DIGIT\n"
      assert {:ok, grammar} = GrammarImport.import_grammar(:abnf, source)
      assert grammar.root == :ip4octet
    end

    test "source that already has real CRLFs isn't double-converted" do
      source = "ip4octet = 1*3DIGIT\r\n"
      assert {:ok, grammar} = GrammarImport.import_grammar(:abnf, source)
      assert grammar.root == :ip4octet
    end
  end

  describe "assemble/3" do
    test "builds a grammar with the given root and @noskip" do
      ruleset = %{a: IR.rule_ref(:b), b: IR.literal("x")}
      grammar = GrammarImport.assemble(ruleset, :a, [])

      assert grammar.root == :a
      assert grammar.skip == nil
    end

    test "token_names are kept as pre-declared tokens, not auto-promoted" do
      ruleset = %{digit: IR.char_class([{?0, ?9}]), a: IR.rule_ref(:digit)}
      grammar = GrammarImport.assemble(ruleset, :a, [:digit])

      assert grammar.tokens[:digit] == IR.char_class([{?0, ?9}])
      assert grammar.rules[:a] == IR.rule_ref(:digit)
      assert map_size(grammar.rules) == 1
    end

    test "structurally identical literals used twice are deduplicated into one anon token" do
      ruleset = %{a: IR.seq([IR.literal("x"), IR.literal("x")])}
      grammar = GrammarImport.assemble(ruleset, :a, [])

      assert map_size(grammar.tokens) == 1
    end
  end
end
