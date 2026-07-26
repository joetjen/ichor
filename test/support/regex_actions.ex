defmodule Regex.Actions do
  @moduledoc """
  Turns the `4.7 regex` grammar's parse tree into an actual
  `Grammar.IR` tree -- the same shape `Aether.Parser`'s own `/pattern/`
  desugaring builds directly from pattern text. Deliberate
  self-reference: this grammar parses exactly the dialect Aether's own
  regex-literal sugar desugars from, so running both over the same
  pattern text and comparing the resulting `Grammar.IR` trees (modulo
  source-span metadata, which naturally differs between the two call
  sites) is a live correctness check between two independently written
  implementations of the same spec.

  Two known, narrow, deliberately-accepted gaps, both stemming from
  Aether's lexer being context-blind (global maximal munch, no notion of
  "inside a character class" as lexer state -- a tradeoff of the lexer
  itself, not something this fixture works around): a bare `-` or `^`
  cannot be matched as a literal character (only via its `ESCAPED_CHAR`
  form, `\\-`/`\\^`) since `DASH`/`CARET` are also referenced directly by
  `range`/`char_class` and so always win the token-length tie against
  `LITERAL_CHAR`. Neither gap is exercised by this grammar's own
  correctness-check pattern.
  """

  @behaviour Ichor.Actions

  alias Grammar.IR

  # ---- leaf tokens -----------------------------------------------------

  @impl true
  def handle_token(:LITERAL_CHAR, text, _ctx), do: {:ok, text}
  def handle_token(:ESCAPED_CHAR, text, _ctx), do: {:ok, decode_escape(text)}
  def handle_token(:DOT, _text, _ctx), do: {:ok, IR.any()}
  def handle_token(:SHORTHAND_CLASS, text, _ctx), do: {:ok, shorthand_ir(text)}
  def handle_token(:STAR, _text, _ctx), do: {:ok, :star}
  def handle_token(:PLUS, _text, _ctx), do: {:ok, :plus}
  def handle_token(:QUESTION, _text, _ctx), do: {:ok, :opt}

  # ---- rules -------------------------------------------------------------

  # `atom`'s `group`/`char_class`/`DOT`/`SHORTHAND_CLASS` alternatives are
  # already `Grammar.IR` nodes by the time they get here (built above, or
  # by this same rule's own `group`/`char_class` clauses below) -- only
  # `LITERAL_CHAR`/`ESCAPED_CHAR` (bare decoded characters, reused as-is
  # by `class_atom` for char-class endpoints) still need wrapping in
  # `IR.literal/1`. Anything else falls through to the default fallback
  # unchanged, via the usual per-call `FunctionClauseError`
  # fallback (`Ichor.Actions.dispatch_rule/5`'s own doc explains why the
  # fallback has to happen at the call site).
  @impl true
  def handle_rule(:atom, %{LITERAL_CHAR: cap}, ctx) do
    with {:ok, char, ctx} <- cap.eval.(ctx), do: {:ok, IR.literal(char), ctx}
  end

  def handle_rule(:atom, %{ESCAPED_CHAR: cap}, ctx) do
    with {:ok, char, ctx} <- cap.eval.(ctx), do: {:ok, IR.literal(char), ctx}
  end

  def handle_rule(:term, captures, ctx) do
    with {:ok, atom_ir, ctx} <- captures.atom.eval.(ctx),
         {:ok, quantified_ir, ctx} <- apply_quantifier(captures, atom_ir, ctx) do
      {:ok, quantified_ir, ctx}
    end
  end

  def handle_rule(:bound, captures, ctx) do
    with {:ok, min_text, ctx} <- captures.min.eval.(ctx) do
      min = String.to_integer(min_text)

      case Map.fetch(captures, :max) do
        {:ok, max_cap} ->
          with {:ok, max_text, ctx} <- max_cap.eval.(ctx) do
            max = if max_text == "", do: :infinity, else: String.to_integer(max_text)
            {:ok, {:rep, min, max}, ctx}
          end

        :error ->
          {:ok, {:rep, min, min}, ctx}
      end
    end
  end

  # `alternative := term*` -- mirrors `Aether.Parser`'s own `regex_terms/4`
  # exactly: zero terms is an empty-string match, one term passes through
  # unwrapped, more than one becomes a `Seq`.
  def handle_rule(:alternative, %{term: terms}, ctx) do
    with {:ok, %{term: irs}, ctx} <- Ichor.Actions.eval_all(%{term: terms}, ctx) do
      {:ok, seq_of(irs), ctx}
    end
  end

  # `pattern := alternative (PIPE alternative)*` -- mirrors `wrap_alts/1`:
  # one alternative passes through, more than one becomes a `Choice`.
  def handle_rule(:pattern, %{alternative: alts}, ctx) do
    with {:ok, %{alternative: irs}, ctx} <- Ichor.Actions.eval_all(%{alternative: alts}, ctx) do
      {:ok, wrap_alts(irs), ctx}
    end
  end

  def handle_rule(:group, captures, ctx) do
    with {:ok, pattern_ir, ctx} <- captures.pattern.eval.(ctx) do
      cond do
        Map.has_key?(captures, :LOOKAHEAD_POS) -> {:ok, IR.and_pred(pattern_ir), ctx}
        Map.has_key?(captures, :LOOKAHEAD_NEG) -> {:ok, IR.not_pred(pattern_ir), ctx}
        true -> {:ok, pattern_ir, ctx}
      end
    end
  end

  def handle_rule(:char_class, captures, ctx) do
    with {:ok, %{class_item: items}, ctx} <-
           Ichor.Actions.eval_all(%{class_item: captures.class_item}, ctx) do
      positive = IR.char_class(Enum.map(items, &to_range/1))

      ir =
        if Map.has_key?(captures, :CARET),
          do: IR.seq([IR.not_pred(positive), IR.any()]),
          else: positive

      {:ok, ir, ctx}
    end
  end

  def handle_rule(:range, %{from: from_cap, to: to_cap}, ctx) do
    with {:ok, from_char, ctx} <- from_cap.eval.(ctx),
         {:ok, to_char, ctx} <- to_cap.eval.(ctx) do
      {:ok, {from_char, to_char}, ctx}
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp decode_escape("\\n"), do: "\n"
  defp decode_escape("\\r"), do: "\r"
  defp decode_escape("\\t"), do: "\t"
  defp decode_escape(<<"\\", c::utf8>>), do: <<c::utf8>>

  defp shorthand_ir("\\d"), do: IR.rule_ref(:DIGIT)
  defp shorthand_ir("\\w"), do: IR.rule_ref(:ALNUM)
  defp shorthand_ir("\\s"), do: IR.rule_ref(:SPACE)
  defp shorthand_ir("\\D"), do: negated_ref(:DIGIT)
  defp shorthand_ir("\\W"), do: negated_ref(:ALNUM)
  defp shorthand_ir("\\S"), do: negated_ref(:SPACE)

  defp negated_ref(name), do: IR.seq([IR.not_pred(IR.rule_ref(name)), IR.any()])

  defp apply_quantifier(%{quantifier: cap}, atom_ir, ctx) do
    with {:ok, q, ctx} <- cap.eval.(ctx) do
      {:ok, quantify(atom_ir, q), ctx}
    end
  end

  defp apply_quantifier(_captures, atom_ir, ctx), do: {:ok, atom_ir, ctx}

  defp quantify(ir, :star), do: IR.star(ir)
  defp quantify(ir, :plus), do: IR.plus(ir)
  defp quantify(ir, :opt), do: IR.opt(ir)
  defp quantify(ir, {:rep, min, max}), do: IR.rep(ir, min, max)

  defp seq_of([]), do: IR.literal("")
  defp seq_of([one]), do: one
  defp seq_of(many), do: IR.seq(many)

  defp wrap_alts([one]), do: one
  defp wrap_alts(many), do: IR.choice(many)

  defp to_range({from, to}), do: {codepoint(from), codepoint(to)}
  defp to_range(char), do: {codepoint(char), codepoint(char)}

  defp codepoint(<<cp::utf8>>), do: cp
end
