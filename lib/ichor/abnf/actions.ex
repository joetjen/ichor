defmodule Ichor.ABNF.Actions do
  @moduledoc """
  Turns a parsed ABNF `rulelist` (RFC 5234 + RFC 7405) into a real
  `%{rule_name_atom => Grammar.IR.expr()}` map -- one `Grammar.IR` tree
  per ABNF rule, mirroring how `Regex.Actions` turns a single
  `/pattern/` into one `Grammar.IR` tree. This is an importer's own
  output, not a runnable `Aether.Grammar` -- ABNF has no lexer/rule
  (token/parser) split the way Aether does, so deciding which of an
  ABNF ruleset's productions become Aether tokens vs. rules is a
  separate concern this module doesn't address.

  Rule names are matched case-insensitively per RFC 5234 (rule name
  comparison is defined to ignore case) -- every name is downcased
  before becoming an atom, so `Ip4-Octet` and `ip4-octet` are the same
  key. `"=/"` (RFC 7405's incremental-alternatives form) appends to an
  already-`"="`-defined rule's own top-level `Grammar.IR.Choice`
  (wrapping a non-`Choice` single alternative into one first); using
  `"=/"` before any `"="` for that name, or repeating a plain `"="` for
  the same name twice, is a real error (`Ichor.Error`, `stage: :action`),
  not silently accepted -- RFC 5234 section 3.3 defines `"=/"` as
  extending a rule that already exists.

  `prose_val` (`<...>`, RFC 5234 section 3.6 -- free-form English text
  standing in for a rule body, "a last resort") has no executable
  meaning at all, so it's rejected the same deliberate way regex's own
  backreferences/named-groups/anchors are: `Ichor.Error`, not silently
  ignored or half-supported.

  One known, narrow, deliberately-accepted gap: a comment trailing a
  rule's own definition on the *same* line isn't supported, only a
  comment on its own line -- real RFC 5234 allows `c-nl = comment /
  CRLF` right after a rule's `elements`; this grammar requires a bare
  `CRLF` there instead.
  """

  @behaviour Ichor.Actions

  alias Grammar.IR

  # ---- leaf tokens -----------------------------------------------------

  @impl true
  def handle_token(:QUOTED_STRING, text, _ctx), do: {:ok, quoted_string_ir(text)}
  def handle_token(:HEX_VAL, text, _ctx), do: {:ok, num_val_ir(text, 16)}
  def handle_token(:BIN_VAL, text, _ctx), do: {:ok, num_val_ir(text, 2)}
  def handle_token(:DEC_VAL, text, _ctx), do: {:ok, num_val_ir(text, 10)}

  def handle_token(:PROSE_VAL, text, _ctx) do
    {:error,
     Ichor.Error.new(
       message:
         "prose-val #{inspect(text)} has no executable meaning -- ABNF's own " <>
           "\"last resort\" escape hatch for a rule that can't be defined in ABNF at all",
       stage: :action
     )}
  end

  # ---- rules -------------------------------------------------------------

  @impl true
  def handle_rule(:rulename_ref, %{RULENAME: cap}, ctx) do
    with {:ok, text, ctx} <- cap.eval.(ctx), do: {:ok, IR.rule_ref(name_to_atom(text)), ctx}
  end

  def handle_rule(:group, captures, ctx), do: captures.alternation.eval.(ctx)

  def handle_rule(:option, captures, ctx) do
    with {:ok, ir, ctx} <- captures.alternation.eval.(ctx), do: {:ok, IR.opt(ir), ctx}
  end

  def handle_rule(:elements, captures, ctx), do: captures.alternation.eval.(ctx)

  # `alternation := concatenation (WSP* SLASH WSP* concatenation)*` --
  # same idiom as `Regex.Actions`'s `pattern := alternative (PIPE
  # alternative)*`: the mandatory first `concatenation` and each starred
  # repeat merge into one ordered list under `:concatenation`.
  def handle_rule(:alternation, %{concatenation: concats}, ctx) do
    with {:ok, %{concatenation: irs}, ctx} <-
           Ichor.Actions.eval_all(%{concatenation: concats}, ctx) do
      {:ok, wrap_alts(irs), ctx}
    end
  end

  # `concatenation := repetition (WSP+ repetition)*` -- same idiom again.
  def handle_rule(:concatenation, %{repetition: reps}, ctx) do
    with {:ok, %{repetition: irs}, ctx} <- Ichor.Actions.eval_all(%{repetition: reps}, ctx) do
      {:ok, seq_of(irs), ctx}
    end
  end

  def handle_rule(:repetition, captures, ctx) do
    with {:ok, element_ir, ctx} <- captures.element.eval.(ctx) do
      case Map.fetch(captures, :repeat) do
        {:ok, repeat_cap} ->
          with {:ok, {min, max}, ctx} <- repeat_cap.eval.(ctx) do
            {:ok, apply_repeat(element_ir, min, max), ctx}
          end

        :error ->
          {:ok, element_ir, ctx}
      end
    end
  end

  # `repeat := (min:(DIGIT*) STAR max:(DIGIT*)) | DIGIT+` -- a named
  # capture *adds* a text capture, it doesn't suppress the wrapped
  # expression's own implicit one, so the first alternative's raw
  # captures are actually `%{min: _, max: _, DIGIT: _, STAR: _}` --
  # `:DIGIT` (both `min:`/`max:`'s inner runs, merged) is present
  # *either way*. Matching on `:min` first (only the first alternative
  # ever has it) before falling back to bare `:DIGIT` (only the second
  # alternative, `DIGIT+`, ever has *only* that) is what actually tells
  # the two apart.
  def handle_rule(:repeat, %{min: min_cap, max: max_cap}, ctx) do
    with {:ok, min_text, ctx} <- min_cap.eval.(ctx),
         {:ok, max_text, ctx} <- max_cap.eval.(ctx) do
      min = if min_text == "", do: 0, else: String.to_integer(min_text)
      max = if max_text == "", do: :infinity, else: String.to_integer(max_text)
      {:ok, {min, max}, ctx}
    end
  end

  def handle_rule(:repeat, %{DIGIT: digit_caps}, ctx) do
    with {:ok, %{DIGIT: texts}, ctx} <- Ichor.Actions.eval_all(%{DIGIT: digit_caps}, ctx) do
      n = texts |> Enum.join() |> String.to_integer()
      {:ok, {n, n}, ctx}
    end
  end

  def handle_rule(:rule, %{RULENAME: name_cap, DEFINED_AS: defined_as_cap} = captures, ctx) do
    with {:ok, name_text, ctx} <- name_cap.eval.(ctx),
         {:ok, defined_as_text, ctx} <- defined_as_cap.eval.(ctx),
         {:ok, ir, ctx} <- captures.elements.eval.(ctx) do
      op = if defined_as_text == "=/", do: :incremental, else: :assign
      {:ok, {name_to_atom(name_text), op, ir}, ctx}
    end
  end

  def handle_rule(:rulelist, %{rule: rule_caps}, ctx) do
    with {:ok, %{rule: rules}, ctx} <- Ichor.Actions.eval_all(%{rule: rule_caps}, ctx),
         {:ok, ruleset} <- build_ruleset(rules) do
      {:ok, ruleset, ctx}
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp name_to_atom(text), do: text |> String.downcase() |> String.to_atom()

  defp apply_repeat(ir, 0, :infinity), do: IR.star(ir)
  defp apply_repeat(ir, 1, :infinity), do: IR.plus(ir)
  defp apply_repeat(ir, 0, 1), do: IR.opt(ir)
  defp apply_repeat(ir, min, max), do: IR.rep(ir, min, max)

  defp seq_of([]), do: IR.literal("")
  defp seq_of([one]), do: one
  defp seq_of(many), do: IR.seq(many)

  defp wrap_alts([one]), do: one
  defp wrap_alts(many), do: IR.choice(many)

  # RFC 5234's own default (a quoted string matches case-insensitively
  # unless RFC 7405's `%s` says otherwise) -- mirrors `Aether.Parser`'s
  # own `"lit"i` desugaring (`desugar_literal/3`) exactly, so a
  # case-insensitive ABNF char-val and an Aether `"lit"i` produce
  # identical `Grammar.IR`.
  defp quoted_string_ir(text) do
    {sensitivity, quoted} =
      cond do
        String.starts_with?(text, "%s") ->
          {:sensitive, binary_part(text, 2, byte_size(text) - 2)}

        String.starts_with?(text, "%i") ->
          {:insensitive, binary_part(text, 2, byte_size(text) - 2)}

        true ->
          {:insensitive, text}
      end

    inner = String.slice(quoted, 1..-2//1)
    char_val_ir(inner, sensitivity)
  end

  defp char_val_ir(text, :sensitive), do: IR.literal(text)

  defp char_val_ir(text, :insensitive) do
    case text |> String.graphemes() |> Enum.map(&case_insensitive_node/1) do
      [] -> IR.literal("")
      [one] -> one
      nodes -> IR.seq(nodes)
    end
  end

  defp case_insensitive_node(grapheme) do
    down = String.downcase(grapheme)
    up = String.upcase(grapheme)

    with true <- down != up,
         <<down_cp::utf8>> <- down,
         <<up_cp::utf8>> <- up do
      IR.char_class([{down_cp, down_cp}, {up_cp, up_cp}])
    else
      _ -> IR.literal(grapheme)
    end
  end

  # `%x41` => one character (codepoint 0x41); `%x0D.0A` => a two-character
  # literal (a concatenation of specific codepoints); `%x30-39` => a
  # single-range char class. Never more than one of "." / "-" appears
  # (the grammar's own `((...)+  | (...))?` alternation guarantees that).
  defp num_val_ir(text, radix) do
    rest = binary_part(text, 2, byte_size(text) - 2)

    cond do
      String.contains?(rest, "-") ->
        [from, to] = String.split(rest, "-", parts: 2)
        IR.char_class([{String.to_integer(from, radix), String.to_integer(to, radix)}])

      String.contains?(rest, ".") ->
        codepoints = rest |> String.split(".") |> Enum.map(&String.to_integer(&1, radix))
        IR.literal(Enum.map_join(codepoints, "", &<<&1::utf8>>))

      true ->
        IR.literal(<<String.to_integer(rest, radix)::utf8>>)
    end
  end

  # ---- rulelist assembly: fold `rule` results into one map, applying
  # RFC 7405's "=/" incremental-alternatives extension in source order --

  defp build_ruleset(rules) do
    Enum.reduce_while(rules, {:ok, %{}}, fn {name, op, ir}, {:ok, acc} ->
      case merge_rule(acc, name, op, ir) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp merge_rule(acc, name, :assign, ir) do
    if Map.has_key?(acc, name) do
      {:error,
       Ichor.Error.new(
         message: "rule #{name} redefined with \"=\" -- use \"=/\" to extend an existing rule",
         stage: :action
       )}
    else
      {:ok, Map.put(acc, name, ir)}
    end
  end

  defp merge_rule(acc, name, :incremental, ir) do
    case Map.fetch(acc, name) do
      {:ok, existing} ->
        {:ok, Map.put(acc, name, extend_choice(existing, ir))}

      :error ->
        {:error,
         Ichor.Error.new(
           message: "rule #{name} extended with \"=/\" before being defined with \"=\"",
           stage: :action
         )}
    end
  end

  defp extend_choice(%IR.Choice{exprs: exprs}, ir), do: IR.choice(exprs ++ [ir])
  defp extend_choice(existing, ir), do: IR.choice([existing, ir])
end
