defmodule Ichor.PEG.Actions do
  @moduledoc """
  Turns a parsed PEG `grammar_file` (Ford's paper, pest/PEG.js-style
  convention) into a real `%{ident_atom => Grammar.IR.expr()}` map --
  one `Grammar.IR` tree per rule, the same target category every other
  importer this project builds uses.

  PEG's own operators (`&`, `!`, `?`, `*`, `+`, `/`, `.`, `[...]`) are
  close to identical in spelling and meaning to Aether's own, so most of
  this module is a thin wrapper. `primary`'s `(IDENT !ARROW)` is real
  disambiguation, not a formality: without the negative lookahead, a
  bare identifier reference inside one rule's expression would be
  ambiguous with the start of the next rule's own definition. It works
  because `!ARROW` is a parser-level predicate checked at every
  candidate identifier, unlike the lexer-level maximal munch that
  causes the equivalent ambiguity in `Ichor.BNF`/`Ichor.EBNF.W3C` (both
  need an explicit newline between rules for exactly this reason; PEG
  doesn't).

  Rule names are kept exactly as written, case-sensitively, matching
  ordinary identifier conventions (no RFC 5234-style case-insensitivity
  rule applies here).

  `[^...]` negates a character class the same way regex's own does:
  `Seq([NotPred(class), Any])`.
  """

  @behaviour Ichor.Actions

  alias Grammar.IR
  alias Ichor.Toolkit.Result

  # ---- leaf tokens -----------------------------------------------------

  @impl true
  def handle_token(:SQ_TERMINAL, text, _ctx), do: {:ok, IR.literal(strip_quotes(text))}
  def handle_token(:DQ_TERMINAL, text, _ctx), do: {:ok, IR.literal(strip_quotes(text))}
  def handle_token(:CHAR_CLASS, text, _ctx), do: {:ok, char_class_ir(text)}

  # ---- rules -------------------------------------------------------------

  @impl true
  def handle_rule(:primary, captures, ctx) do
    cond do
      Map.has_key?(captures, :expression) -> captures.expression.eval.(ctx)
      Map.has_key?(captures, :literal) -> captures.literal.eval.(ctx)
      Map.has_key?(captures, :char_class) -> captures.char_class.eval.(ctx)
      Map.has_key?(captures, :DOT) -> {:ok, IR.any(), ctx}
      Map.has_key?(captures, :IDENT) -> ident_ref(Map.fetch!(captures, :IDENT), ctx)
    end
  end

  def handle_rule(:suffix, %{primary: primary_cap} = captures, ctx) do
    with {:ok, primary_ir, ctx} <- primary_cap.eval.(ctx) do
      cond do
        Map.has_key?(captures, :QUESTION) -> {:ok, IR.opt(primary_ir), ctx}
        Map.has_key?(captures, :STAR) -> {:ok, IR.star(primary_ir), ctx}
        Map.has_key?(captures, :PLUS) -> {:ok, IR.plus(primary_ir), ctx}
        true -> {:ok, primary_ir, ctx}
      end
    end
  end

  def handle_rule(:prefix, %{suffix: suffix_cap} = captures, ctx) do
    with {:ok, suffix_ir, ctx} <- suffix_cap.eval.(ctx) do
      cond do
        Map.has_key?(captures, :AMP) -> {:ok, IR.and_pred(suffix_ir), ctx}
        Map.has_key?(captures, :BANG) -> {:ok, IR.not_pred(suffix_ir), ctx}
        true -> {:ok, suffix_ir, ctx}
      end
    end
  end

  # `sequence := prefix*` -- may be genuinely empty (matches epsilon),
  # unlike every other front-end's bare-repeated-element rule, which are
  # all `X+`. `capture_shapes` still guarantees `:prefix` is present (as
  # `[]`) even then.
  def handle_rule(:sequence, %{prefix: prefixes}, ctx) do
    with {:ok, %{prefix: irs}, ctx} <- Ichor.Actions.eval_all(%{prefix: prefixes}, ctx) do
      {:ok, seq_of(irs), ctx}
    end
  end

  # `expression := sequence (SLASH sequence)*` -- same idiom as every
  # other front-end's own alternation.
  def handle_rule(:expression, %{sequence: seqs}, ctx) do
    with {:ok, %{sequence: irs}, ctx} <- Ichor.Actions.eval_all(%{sequence: seqs}, ctx) do
      {:ok, wrap_alts(irs), ctx}
    end
  end

  def handle_rule(:rule, %{IDENT: name_cap} = captures, ctx) do
    with {:ok, name_text, ctx} <- name_cap.eval.(ctx),
         {:ok, ir, ctx} <- captures.expression.eval.(ctx) do
      {:ok, {String.to_atom(name_text), ir}, ctx}
    end
  end

  def handle_rule(:grammar_file, %{rule: rule_caps}, ctx) do
    with {:ok, %{rule: rules}, ctx} <- Ichor.Actions.eval_all(%{rule: rule_caps}, ctx),
         {:ok, ruleset} <- build_ruleset(rules) do
      {:ok, ruleset, ctx}
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp ident_ref(cap, ctx) do
    with {:ok, text, ctx} <- cap.eval.(ctx), do: {:ok, IR.rule_ref(String.to_atom(text)), ctx}
  end

  defp strip_quotes(text), do: String.slice(text, 1..-2//1)

  defp char_class_ir(text) do
    inner = String.slice(text, 1..-2//1)

    {negated?, inner} =
      if String.starts_with?(inner, "^") do
        {true, String.slice(inner, 1..-1//1)}
      else
        {false, inner}
      end

    ranges = inner |> class_atoms() |> group_atoms()
    positive = IR.char_class(ranges)
    if negated?, do: IR.seq([IR.not_pred(positive), IR.any()]), else: positive
  end

  defp class_atoms(""), do: []
  defp class_atoms(<<cp::utf8, rest::binary>>), do: [cp | class_atoms(rest)]

  defp group_atoms([a, ?-, b | rest]), do: [{a, b} | group_atoms(rest)]
  defp group_atoms([a | rest]), do: [{a, a} | group_atoms(rest)]
  defp group_atoms([]), do: []

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
           message: "rule #{inspect(name)} defined more than once",
           stage: :action
         )}
      else
        {:ok, Map.put(acc, name, ir)}
      end
    end)
  end
end
