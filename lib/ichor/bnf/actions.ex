defmodule Ichor.BNF.Actions do
  @moduledoc """
  Turns a parsed classical BNF `grammar_file` into a real
  `%{nonterminal_name_atom => Grammar.IR.expr()}` map -- one
  `Grammar.IR` tree per rule, the same target category `Ichor.ABNF.Actions`
  and `Regex.Actions` both use.

  Classical BNF has no single citable standard; this follows the ALGOL
  60 Report's own convention for everything except terminal symbols --
  the strictest reading of the Report leaves those unquoted, distinguished
  from nonterminals only by the reader already knowing the target
  language's keyword set. This grammar quotes terminals instead
  (`'lit'`/`"lit"`), matching how BNF is actually written in nearly
  every modern presentation of it -- a deliberate deviation from the
  Report's strictest reading, not an oversight.

  Unlike ABNF (RFC 5234's rule names are explicitly case-insensitive),
  classical BNF has no such spec-level rule -- nonterminal names are
  kept exactly as written, not downcased.

  Rules are separated by an explicit newline (`@skip`'s own token only
  covers space/tab within one rule) -- `sequence := element+`'s own
  greedy repetition can't otherwise tell "one more element of this
  rule" apart from "the next rule's own opening nonterminal, on the
  next line," since both parse identically as an `element`.
  """

  @behaviour Ichor.Actions

  alias Grammar.IR
  alias Ichor.Toolkit.Result

  # ---- leaf tokens -----------------------------------------------------

  @impl true
  def handle_token(:SQ_TERMINAL, text, _ctx), do: {:ok, IR.literal(strip_quotes(text))}
  def handle_token(:DQ_TERMINAL, text, _ctx), do: {:ok, IR.literal(strip_quotes(text))}

  # ---- rules -------------------------------------------------------------

  @impl true
  def handle_rule(:nonterminal, %{NONTERM_NAME: cap}, ctx) do
    with {:ok, text, ctx} <- cap.eval.(ctx), do: {:ok, IR.rule_ref(String.to_atom(text)), ctx}
  end

  # `sequence := element+` -- a list-valued single capture still isn't
  # unwrapped by the default fallback (only a *non-repeated* single
  # capture is), so this needs its own clause even though `element+`
  # only ever produces the one key.
  def handle_rule(:sequence, %{element: elements}, ctx) do
    with {:ok, %{element: irs}, ctx} <- Ichor.Actions.eval_all(%{element: elements}, ctx) do
      {:ok, seq_of(irs), ctx}
    end
  end

  # `alternatives := sequence (BAR sequence)*` -- same idiom as
  # `Ichor.ABNF.Actions`'s `alternation`/`Regex.Actions`'s `pattern`: the
  # mandatory first `sequence` and each starred repeat merge into one
  # ordered list under `:sequence`.
  def handle_rule(:alternatives, %{sequence: seqs}, ctx) do
    with {:ok, %{sequence: irs}, ctx} <- Ichor.Actions.eval_all(%{sequence: seqs}, ctx) do
      {:ok, wrap_alts(irs), ctx}
    end
  end

  def handle_rule(:rule, %{nonterminal: name_cap} = captures, ctx) do
    with {:ok, %IR.RuleRef{name: name}, ctx} <- name_cap.eval.(ctx),
         {:ok, ir, ctx} <- captures.alternatives.eval.(ctx) do
      {:ok, {name, ir}, ctx}
    end
  end

  def handle_rule(:grammar_file, %{rule: rule_caps}, ctx) do
    with {:ok, %{rule: rules}, ctx} <- Ichor.Actions.eval_all(%{rule: rule_caps}, ctx),
         {:ok, ruleset} <- build_ruleset(rules) do
      {:ok, ruleset, ctx}
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp strip_quotes(text), do: String.slice(text, 1..-2//1)

  defp seq_of([]), do: IR.literal("")
  defp seq_of([one]), do: one
  defp seq_of(many), do: IR.seq(many)

  defp wrap_alts([one]), do: one
  defp wrap_alts(many), do: IR.choice(many)

  defp build_ruleset(rules) do
    Result.reduce_ok(rules, %{}, fn {name, ir}, acc ->
      if Map.has_key?(acc, name) do
        {:error,
         Ichor.Error.new(
           message: "nonterminal <#{name}> defined more than once",
           stage: :action
         )}
      else
        {:ok, Map.put(acc, name, ir)}
      end
    end)
  end
end
