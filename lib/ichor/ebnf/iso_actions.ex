defmodule Ichor.EBNF.ISO.Actions do
  @moduledoc """
  Turns a parsed ISO/IEC 14977 EBNF `syntax` into a real
  `%{meta_identifier_atom => Grammar.IR.expr()}` map -- one `Grammar.IR`
  tree per rule, the same target category `Ichor.ABNF.Actions` and
  `Ichor.BNF.Actions` both use.

  Meta-identifier names are kept exactly as written (leading/trailing
  whitespace trimmed off the token's own greedy trailing-space capture
  -- ISO EBNF's `IDENT` allows an embedded literal space, but internal
  spacing, e.g. `syntax rule`, is preserved, since ISO EBNF really does
  allow multi-word identifiers). No case-insensitivity rule the way
  ABNF's RFC 5234 has one.

  An empty alternative (`x = 'a' | ;`) is expressed as `single_definition`
  matching zero-width via a rule-level `Opt` around its own body, not a
  token -- Aether's own lexer never treats a zero-length match as "the
  next token" (needed so tokenization itself can't stall forever on an
  always-matches-empty token), so a token-based encoding of "empty"
  referenced from a rule could never actually match, at any position.

  **The exception operator (`-`) is a best-effort, not a full
  language-theoretic set difference.** ISO EBNF's `factor - exception`
  means "every string `factor` generates that `exception` doesn't
  generate" -- true set subtraction, which `Grammar.IR` has no
  combinator for (`NotPred` is PEG lookahead at the *current* parse
  position, not "matches `factor`'s language minus `exception`'s").
  This translates it as `Seq([NotPred(exception), factor])`: reject
  first if `exception` would also match here, then require `factor` --
  correct when the excluded language is a lookahead-distinguishable
  prefix of the included one (e.g. `digit - '0'`, a factor that's a
  plain alternation of single characters and an exception that's one of
  them), but not a claim of full correctness for arbitrary
  `factor`/`exception` pairs in general.

  `special_sequence` (`? ... ?`, ISO's own escape hatch for
  implementation-defined extensions the formal grammar doesn't cover)
  has no executable meaning, so it's rejected the same deliberate way
  ABNF's `prose_val` and regex's backreferences/named-groups/anchors
  are: `Ichor.Error`, not silently ignored.
  """

  @behaviour Ichor.Actions

  alias Grammar.IR
  alias Ichor.Toolkit.Result

  # ---- leaf tokens -----------------------------------------------------

  @impl true
  def handle_token(:IDENT, text, _ctx), do: {:ok, String.trim(text)}
  def handle_token(:SQ_TERMINAL, text, _ctx), do: {:ok, IR.literal(strip_quotes(text))}
  def handle_token(:DQ_TERMINAL, text, _ctx), do: {:ok, IR.literal(strip_quotes(text))}

  def handle_token(:SPECIAL_SEQ, text, _ctx) do
    {:error,
     Ichor.Error.new(
       message:
         "special sequence #{inspect(text)} has no executable meaning -- ISO EBNF's own " <>
           "escape hatch for implementation-defined extensions the formal grammar doesn't cover",
       stage: :action
     )}
  end

  # ---- rules -------------------------------------------------------------

  @impl true
  def handle_rule(:meta_identifier, %{IDENT: cap}, ctx) do
    with {:ok, text, ctx} <- cap.eval.(ctx), do: {:ok, IR.rule_ref(String.to_atom(text)), ctx}
  end

  def handle_rule(:optional_seq, captures, ctx) do
    with {:ok, ir, ctx} <- captures.definitions_list.eval.(ctx), do: {:ok, IR.opt(ir), ctx}
  end

  def handle_rule(:repeated_seq, captures, ctx) do
    with {:ok, ir, ctx} <- captures.definitions_list.eval.(ctx), do: {:ok, IR.star(ir), ctx}
  end

  def handle_rule(:grouped_seq, captures, ctx), do: captures.definitions_list.eval.(ctx)

  def handle_rule(:repeat_count, %{DIGIT: digit_caps}, ctx) do
    with {:ok, %{DIGIT: texts}, ctx} <- Ichor.Actions.eval_all(%{DIGIT: digit_caps}, ctx) do
      {:ok, texts |> Enum.join() |> String.to_integer(), ctx}
    end
  end

  def handle_rule(:factor, %{primary: primary_cap} = captures, ctx) do
    with {:ok, primary_ir, ctx} <- primary_cap.eval.(ctx) do
      case Map.fetch(captures, :repeat_count) do
        {:ok, count_cap} ->
          with {:ok, n, ctx} <- count_cap.eval.(ctx), do: {:ok, IR.rep(primary_ir, n, n), ctx}

        :error ->
          {:ok, primary_ir, ctx}
      end
    end
  end

  def handle_rule(:term, %{factor: factor_cap} = captures, ctx) do
    with {:ok, factor_ir, ctx} <- factor_cap.eval.(ctx) do
      case Map.fetch(captures, :exception) do
        {:ok, exception_cap} ->
          with {:ok, exception_ir, ctx} <- exception_cap.eval.(ctx) do
            {:ok, IR.seq([IR.not_pred(exception_ir), factor_ir]), ctx}
          end

        :error ->
          {:ok, factor_ir, ctx}
      end
    end
  end

  # `single_definition := (term (COMMA term)*)?` -- when the whole thing
  # matched zero-width (ISO's own empty alternative, see this module's
  # own moduledoc), there are no captures at all; a real match always
  # has at least `:term`.
  def handle_rule(:single_definition, captures, ctx) when map_size(captures) == 0 do
    {:ok, IR.literal(""), ctx}
  end

  def handle_rule(:single_definition, %{term: terms}, ctx) do
    with {:ok, %{term: irs}, ctx} <- Ichor.Actions.eval_all(%{term: terms}, ctx) do
      {:ok, seq_of(irs), ctx}
    end
  end

  # `definitions_list := single_definition (BAR single_definition)*` --
  # same idiom as every other front-end's own alternation: the
  # mandatory first `single_definition` and each starred repeat merge
  # into one ordered list under `:single_definition`.
  def handle_rule(:definitions_list, %{single_definition: defs}, ctx) do
    with {:ok, %{single_definition: irs}, ctx} <-
           Ichor.Actions.eval_all(%{single_definition: defs}, ctx) do
      {:ok, wrap_alts(irs), ctx}
    end
  end

  def handle_rule(:syntax_rule, %{meta_identifier: name_cap} = captures, ctx) do
    with {:ok, %IR.RuleRef{name: name}, ctx} <- name_cap.eval.(ctx),
         {:ok, ir, ctx} <- captures.definitions_list.eval.(ctx) do
      {:ok, {name, ir}, ctx}
    end
  end

  def handle_rule(:syntax, %{syntax_rule: rule_caps}, ctx) do
    with {:ok, %{syntax_rule: rules}, ctx} <-
           Ichor.Actions.eval_all(%{syntax_rule: rule_caps}, ctx),
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
           message: "meta-identifier #{inspect(name)} defined more than once",
           stage: :action
         )}
      else
        {:ok, Map.put(acc, name, ir)}
      end
    end)
  end
end
