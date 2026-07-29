defmodule Support.CrossFormat do
  @moduledoc """
  Cross-format validation: assembles a bare `%Aether.Grammar{}` directly
  from a `%{name => Grammar.IR.expr()}` ruleset -- the shape every one of
  this project's own importers (`Ichor.ABNF`, `Ichor.EBNF.ISO`,
  `Ichor.PEG`) produces -- so it can be
  run through the same `Grammar.VM`/`Grammar.Analysis` machinery every
  native Aether grammar already uses, without going through
  `Aether.Parser` at all.

  None of ABNF, ISO EBNF, or PEG (as specified, and as this project's
  own importers implement them) have Aether's own named-capture syntax
  (`name:expr`) or its `@skip` auto-splicing convenience -- both are
  Aether-specific features, not properties of the target formats. That
  makes reusing an existing language's own `Ichor.Actions` module
  (`Calculator.Actions` etc., which pattern-matches on named captures
  like `captures.op`) meaningless for an imported grammar: the raw
  capture tree structurally can't carry those names. What *is*
  meaningful, and what this module is for, is bare-recognizer
  equivalence: does the imported grammar accept and reject the exact
  same strings the native Aether version does. That's `Grammar.IR`
  being format-agnostic in the sense this module can actually verify --
  same language recognized, not "the same named captures happen to
  exist," which no non-Aether format was ever going to have anyway.
  """

  alias Grammar.IR

  @doc """
  Builds a grammar from `ruleset` (as returned by `Ichor.ABNF.run/1` /
  `Ichor.EBNF.ISO.run/1` / `Ichor.PEG.run/1`), `root` (an atom naming
  the entry rule), and `token_names` (the subset of `ruleset` keys that
  are lexical/terminal -- everything else becomes a parser rule).
  Delegates to `Ichor.GrammarImport.assemble/3` -- promoted to `lib/`
  once `mix ichor.gen` needed this exact assembly for real, not just
  for this test suite's own cross-format equivalence checks; see that
  module's own docs for the full reasoning (`@noskip` always, bare
  literal/char-class promotion into synthetic tokens, ...).
  """
  @spec assemble(%{atom() => Grammar.IR.expr()}, atom(), [atom()]) :: Aether.Grammar.t()
  defdelegate assemble(ruleset, root, token_names), to: Ichor.GrammarImport

  @doc "Runs `grammar` (already analyzed) as a bare recognizer, true/false only -- for asserting accept/reject parity against a native grammar's own test inputs."
  @spec accepts?(Aether.Grammar.t(), String.t()) :: boolean()
  def accepts?(grammar, input) do
    match?({:ok, _pos}, Grammar.VM.parse(grammar, input))
  end

  @doc "Reads an ABNF fixture and normalizes its line endings to CRLF -- RFC 5234's own `CRLF` token requires it, regardless of what line endings the file happens to be saved with on disk."
  @spec read_abnf!(String.t()) :: String.t()
  def read_abnf!(path), do: path |> File.read!() |> read_abnf_source!()

  @doc "Same normalization as `read_abnf!/1`, but for ABNF source already in memory (an inline `~S\"\"\"` fixture, e.g.) rather than read from a file."
  @spec read_abnf_source!(String.t()) :: String.t()
  def read_abnf_source!(source) do
    source |> String.replace("\r\n", "\n") |> String.replace("\n", "\r\n")
  end

  @doc """
  Renames every `RuleRef` in `ir` per `mapping` (unmatched names pass
  through unchanged) -- for comparing a token structurally against a
  native Aether one when the two independently name an equivalent leaf
  primitive differently (e.g. an imported grammar's own `digit-char`
  rule vs. Aether's predefined `DIGIT` token; ABNF/EBNF/PEG rule names
  are conventional identifiers with no reason to match Aether's own
  `ALL_CAPS`-for-tokens convention, or RFC 5234's own case-insensitivity
  downcasing every ABNF name regardless). Structural comparison after
  renaming is the meaningful question -- byte-identical names never
  will be, and were never going to be, without artificially contorting
  the import source just to make names line up.
  """
  @spec rename_refs(IR.expr(), %{atom() => atom()}) :: IR.expr()
  def rename_refs(%IR.RuleRef{name: name} = ref, mapping),
    do: %{ref | name: Map.get(mapping, name, name)}

  def rename_refs(%IR.Seq{exprs: exprs} = node, mapping),
    do: %{node | exprs: Enum.map(exprs, &rename_refs(&1, mapping))}

  def rename_refs(%IR.Choice{exprs: exprs} = node, mapping),
    do: %{node | exprs: Enum.map(exprs, &rename_refs(&1, mapping))}

  def rename_refs(%{expr: inner} = node, mapping),
    do: %{node | expr: rename_refs(inner, mapping)}

  def rename_refs(leaf, _mapping), do: leaf

  @doc "`Grammar.Analysis.run/1`, raising on failure -- every cross-format fixture is hand-written to already be analysis-clean, so a failure here means the fixture itself is broken, not a language-level rejection worth reporting as `{:error, _}`."
  @spec analyze!(Aether.Grammar.t()) :: Aether.Grammar.t()
  def analyze!(grammar) do
    case Grammar.Analysis.run(grammar) do
      {:ok, grammar} -> grammar
      {:error, errors} -> raise "cross-format fixture failed analysis: #{inspect(errors)}"
    end
  end
end
