defmodule LogQL.Actions do
  @moduledoc """
  A "Query (SQL, LogQL)"-style `Ichor.Actions` module, same as
  `SQL.Actions`: eager evaluation in order, and the root
  rule executes the assembled query against a context-provided data
  source. Context here is `%{streams: [%{labels: %{String.t() =>
  String.t()}, lines: [String.t()]}]}` -- `query`'s own action selects
  every stream whose labels satisfy all of `stream_selector`'s matchers,
  concatenates their lines, then threads that line list through each
  `pipeline_stage` in order.

  `line_format_stage`/`logfmt_stage`/`json_stage` are deliberately
  simplified: real Loki templates/structured-field extraction are a
  large surface of their own, well beyond what this fragment needs to
  prove -- that a query executes against a context-provided data
  source. `logfmt_stage`/`json_stage` are
  identity stages; `line_format_stage` replaces each line with its
  format string literally, not a real template expansion.

  Getting a real query to execute at all first required fixing two
  structural issues in the grammar itself (not just the Actions layer):
  `pipeline_stage`'s original `PIPE (filter_expr | ...)` shape required
  a bare `|` before every stage, but `filter_expr`'s own operator token
  (`|=`, `!=`, `|~`, `!~`) already starts with the pipe/bang -- real
  LogQL filter expressions have no separate leading `|` at all (only
  `line_format`/`logfmt`/`json` stages do). And `MATCH_OP`/`FILTER_OP`
  both declared `!=` (and `!~`) as their own alternative, which
  maximal-munch tie-breaking can only ever resolve one way, breaking
  whichever token lost; splitting the six operator characters into their
  own single-purpose tokens (`EQ`/`NEQ`/`EQ_TILDE`/`NEQ_TILDE`/`PIPE_EQ`/
  `PIPE_TILDE`), shared by the now-rule-level `match_op`/`filter_op`,
  resolves it the same way `class_atom` did for the regex grammar.
  """

  @behaviour Ichor.Actions

  @type context :: %{streams: [%{labels: %{String.t() => String.t()}, lines: [String.t()]}]}

  # ---- leaf tokens -----------------------------------------------------

  @impl true
  def handle_token(:IDENT, text, _ctx), do: {:ok, text}
  def handle_token(:STRING, text, _ctx), do: {:ok, String.slice(text, 1..-2//1)}
  def handle_token(:EQ, _text, _ctx), do: {:ok, :eq}
  def handle_token(:NEQ, _text, _ctx), do: {:ok, :neq}
  def handle_token(:EQ_TILDE, _text, _ctx), do: {:ok, :eq_tilde}
  def handle_token(:NEQ_TILDE, _text, _ctx), do: {:ok, :neq_tilde}
  def handle_token(:PIPE_EQ, _text, _ctx), do: {:ok, :contains}
  def handle_token(:PIPE_TILDE, _text, _ctx), do: {:ok, :regex}
  def handle_token(:LOGFMT, _text, _ctx), do: {:ok, & &1}
  def handle_token(:JSON, _text, _ctx), do: {:ok, & &1}

  # ---- rules -------------------------------------------------------------

  @impl true
  def handle_rule(:label_matcher, %{IDENT: field_cap, match_op: op_cap, STRING: value_cap}, ctx) do
    with {:ok, field, ctx} <- field_cap.eval.(ctx),
         {:ok, op, ctx} <- op_cap.eval.(ctx),
         {:ok, value, ctx} <- value_cap.eval.(ctx) do
      {:ok, {field, op, value}, ctx}
    end
  end

  def handle_rule(:stream_selector, %{label_matcher: caps}, ctx) do
    with {:ok, %{label_matcher: matchers}, ctx} <-
           Ichor.Actions.eval_all(%{label_matcher: caps}, ctx) do
      {:ok, matchers, ctx}
    end
  end

  def handle_rule(:filter_expr, %{filter_op: op_cap, STRING: value_cap}, ctx) do
    with {:ok, op, ctx} <- op_cap.eval.(ctx),
         {:ok, value, ctx} <- value_cap.eval.(ctx) do
      {:ok, fn lines -> Enum.filter(lines, &line_matches?(op, value, &1)) end, ctx}
    end
  end

  def handle_rule(:line_format_stage, %{STRING: value_cap}, ctx) do
    with {:ok, value, ctx} <- value_cap.eval.(ctx) do
      {:ok, fn lines -> Enum.map(lines, fn _line -> value end) end, ctx}
    end
  end

  def handle_rule(:pipeline_stage, %{filter_expr: cap}, ctx), do: cap.eval.(ctx)
  def handle_rule(:pipeline_stage, %{line_format_stage: cap}, ctx), do: cap.eval.(ctx)
  def handle_rule(:pipeline_stage, %{logfmt_stage: cap}, ctx), do: cap.eval.(ctx)
  def handle_rule(:pipeline_stage, %{json_stage: cap}, ctx), do: cap.eval.(ctx)

  def handle_rule(:query, %{stream_selector: selector_cap, pipeline_stage: stage_caps}, ctx) do
    with {:ok, matchers, ctx} <- selector_cap.eval.(ctx),
         {:ok, %{pipeline_stage: stages}, ctx} <-
           Ichor.Actions.eval_all(%{pipeline_stage: stage_caps}, ctx) do
      lines =
        ctx.streams
        |> Enum.filter(fn stream -> Enum.all?(matchers, &label_matches?(stream.labels, &1)) end)
        |> Enum.flat_map(& &1.lines)

      {:ok, Enum.reduce(stages, lines, fn stage, lines -> stage.(lines) end), ctx}
    end
  end

  # ---- matching ------------------------------------------------------------

  defp label_matches?(labels, {field, op, value}) do
    actual = Map.get(labels, field, "")

    case op do
      :eq -> actual == value
      :neq -> actual != value
      :eq_tilde -> regex_match?(value, actual)
      :neq_tilde -> not regex_match?(value, actual)
    end
  end

  defp line_matches?(:contains, value, line), do: String.contains?(line, value)
  defp line_matches?(:neq, value, line), do: not String.contains?(line, value)
  defp line_matches?(:regex, value, line), do: regex_match?(value, line)
  defp line_matches?(:neq_tilde, value, line), do: not regex_match?(value, line)

  defp regex_match?(pattern, text) do
    case Regex.compile(pattern) do
      {:ok, re} -> Regex.match?(re, text)
      {:error, _} -> false
    end
  end
end
