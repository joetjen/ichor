defmodule Ichor.EBNF.W3C.Actions do
  @moduledoc """
  Turns a parsed W3C-style EBNF `grammar_file` (the notation the XML 1.0
  spec's own section 6 uses, also shared by XQuery/XPath's grammars)
  into a real `%{ident_atom => Grammar.IR.expr()}` map -- one
  `Grammar.IR` tree per rule, the same target category every other
  importer this project builds uses.

  A `[...]` character class is matched as one token (`CHAR_CLASS`) and
  its interior parsed as plain text here (`handle_token(:CHAR_CLASS,
  ...)`), splitting on `-` for ranges and decoding `#xNN` escapes along
  the way -- exactly the kind of lexing a real character-class parser
  does, rather than asking Aether's own per-character tokenizer to
  agree with a rule-reference token (`IDENT`) about where one class
  member ends and the next begins (they don't, in general: adjacent
  range boundaries with no separator, like `[a-zA-Z0-9]`'s `zA`, are
  genuinely ambiguous between "two single characters" and "one
  multi-character identifier").

  The exception operator (`sequence := term (DASH term)?`) gets the
  same best-effort treatment as `Ichor.EBNF.ISO.Actions`'s own: `Seq([
  NotPred(exception), factor])`, not a true language-theoretic set
  difference (`Grammar.IR` has no combinator for that). Unlike ISO
  EBNF's `term`/`exception` (two different rule names), W3C's `sequence
  := term (DASH term)?` reuses the *same* rule name for both, so
  whether the optional second `term` matched determines whether
  `:term`'s own raw capture is a single value or a two-element list --
  handled explicitly below, not by `Ichor.Actions`'s default fallback.
  """

  @behaviour Ichor.Actions

  alias Grammar.IR

  # ---- leaf tokens -----------------------------------------------------

  @impl true
  def handle_token(:SQ_TERMINAL, text, _ctx), do: {:ok, IR.literal(strip_quotes(text))}
  def handle_token(:DQ_TERMINAL, text, _ctx), do: {:ok, IR.literal(strip_quotes(text))}
  def handle_token(:HEX_REF, text, _ctx), do: {:ok, IR.literal(<<hex_ref_codepoint(text)::utf8>>)}
  def handle_token(:CHAR_CLASS, text, _ctx), do: {:ok, char_class_ir(text)}

  # ---- rules -------------------------------------------------------------

  @impl true
  def handle_rule(:primary, captures, ctx) do
    cond do
      Map.has_key?(captures, :expression) -> captures.expression.eval.(ctx)
      Map.has_key?(captures, :literal) -> captures.literal.eval.(ctx)
      Map.has_key?(captures, :char_class) -> captures.char_class.eval.(ctx)
      Map.has_key?(captures, :hex_ref) -> captures.hex_ref.eval.(ctx)
      Map.has_key?(captures, :IDENT) -> ident_ref(Map.fetch!(captures, :IDENT), ctx)
    end
  end

  def handle_rule(:factor, %{primary: primary_cap} = captures, ctx) do
    with {:ok, primary_ir, ctx} <- primary_cap.eval.(ctx) do
      cond do
        Map.has_key?(captures, :QUESTION) -> {:ok, IR.opt(primary_ir), ctx}
        Map.has_key?(captures, :STAR) -> {:ok, IR.star(primary_ir), ctx}
        Map.has_key?(captures, :PLUS) -> {:ok, IR.plus(primary_ir), ctx}
        true -> {:ok, primary_ir, ctx}
      end
    end
  end

  # `term := factor+` -- same idiom as every other front-end's own
  # bare-repeated-element rule: the mandatory first `factor` and each
  # starred repeat merge into one ordered list under `:factor`.
  def handle_rule(:term, %{factor: factors}, ctx) do
    with {:ok, %{factor: irs}, ctx} <- Ichor.Actions.eval_all(%{factor: factors}, ctx) do
      {:ok, seq_of(irs), ctx}
    end
  end

  # `sequence := term (DASH term)?` -- both the mandatory `term` and the
  # optional exception's `term` are bare references to the *same* rule
  # name, so whether the exception matched determines whether `:term`
  # is a single capture or a two-element list (see this module's own
  # moduledoc).
  def handle_rule(:sequence, %{term: [factor_cap, exception_cap]}, ctx) do
    with {:ok, factor_ir, ctx} <- factor_cap.eval.(ctx),
         {:ok, exception_ir, ctx} <- exception_cap.eval.(ctx) do
      {:ok, IR.seq([IR.not_pred(exception_ir), factor_ir]), ctx}
    end
  end

  def handle_rule(:sequence, %{term: factor_cap}, ctx), do: factor_cap.eval.(ctx)

  # `expression := sequence (BAR sequence)*` -- same idiom as `term`.
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

  defp hex_ref_codepoint("#x" <> hex), do: String.to_integer(hex, 16)

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

  defp class_atoms("#x" <> rest) do
    {hex, rest} = take_hex(rest, "")
    [String.to_integer(hex, 16) | class_atoms(rest)]
  end

  defp class_atoms(<<cp::utf8, rest::binary>>), do: [cp | class_atoms(rest)]

  defp take_hex(<<c, rest::binary>>, acc) when c in ?0..?9 or c in ?a..?f or c in ?A..?F,
    do: take_hex(rest, acc <> <<c>>)

  defp take_hex(rest, acc), do: {acc, rest}

  defp group_atoms([a, ?-, b | rest]), do: [{a, b} | group_atoms(rest)]
  defp group_atoms([a | rest]), do: [{a, a} | group_atoms(rest)]
  defp group_atoms([]), do: []

  defp seq_of([]), do: IR.literal("")
  defp seq_of([one]), do: one
  defp seq_of(many), do: IR.seq(many)

  defp wrap_alts([one]), do: one
  defp wrap_alts(many), do: IR.choice(many)

  defp build_ruleset(rules) do
    Enum.reduce_while(rules, {:ok, %{}}, fn {name, ir}, {:ok, acc} ->
      if Map.has_key?(acc, name) do
        {:halt,
         {:error,
          Ichor.Error.new(
            message: "rule #{inspect(name)} defined more than once",
            stage: :action
          )}}
      else
        {:cont, {:ok, Map.put(acc, name, ir)}}
      end
    end)
  end
end
