defmodule Ichor.Toolkit.Pratt do
  @moduledoc """
  Precedence-climbing (Pratt) expression parsing over a runtime-mutable
  operator table -- extracted from a pattern already hand-rolled once,
  `OpExprTest.Operators.climb/6` (`test/support/opexpr_operators.ex`),
  the worked example proving `Grammar.IR.Custom`/`@native(...)` rule-
  position dispatch works at all. That fixture only ever needed infix
  chains; this generalizes to prefix and postfix too, since those are
  exactly what Track 1's own motivating scenarios need (Prolog's
  `op/3` supports `fy`/`fx` prefix and `xf`/`yf` postfix operators
  alongside infix ones, Haskell fixity declarations are infix-only but
  mixfix notation is not).

  Completely IR-agnostic, like `Ichor.Toolkit.Codegen`/`Result`: `pos`,
  the stream, and the parsed value are all opaque to this module.
  `peek_op` returning `{op_name, pos_after_op}` rather than just
  `op_name` is deliberate, not incidental -- an operator token may sit
  behind skippable trivia (whitespace, comments; `@native(...)` nodes
  are opaque to Aether's own `@skip` splicing, so a caller has to handle
  this itself, same as `climb/6` already did), so *where the operator
  actually ends* can't be assumed to be a fixed offset from where the
  search for it started. `parse_primary` is trusted to do its own
  leading-trivia handling for the same reason.

  ## The infix/postfix ambiguity

  An operator registered as *both* infix and postfix at once is
  genuinely ambiguous: after parsing a left operand and seeing that
  token, nothing short of looking further ahead can tell whether an
  infix use (expecting a right operand next) or a postfix use (expecting
  nothing) was meant. This is exactly why ISO Prolog's own `op/3`
  forbids defining an atom as both infix and postfix -- the same
  operator serving as prefix *and* infix (unary vs. binary `-`) or
  prefix *and* postfix has no such problem, since prefix is only ever
  attempted before a left operand exists and infix/postfix only after,
  two mutually exclusive positions.

  The table itself doesn't reject the combination -- it has no way to
  know at build time whether a caller will later supply the means to
  resolve it, since callbacks are only ever known at `parse/4` call
  time, not baked into the table. Instead, `parse/4` only raises when it
  actually encounters a token where *both* fixities are simultaneously
  viable at the current precedence: if `callbacks` includes
  `can_start_operand?`, it's consulted (does a valid operand start right
  after the operator? infix if so, postfix if not); if it's absent,
  `parse/4` raises `ArgumentError` naming the operator, rather than
  silently misparsing one way or the other.
  """

  @type op_name :: term()
  @type assoc :: :left | :right | :none
  @type fixity :: :prefix | :infix | :postfix
  @type table :: %{
          optional(op_name()) => %{
            optional(:prefix) => non_neg_integer(),
            optional(:infix) => {non_neg_integer(), assoc()},
            optional(:postfix) => non_neg_integer()
          }
        }
  @type callbacks :: %{
          required(:peek_op) => (term() -> {op_name(), term()} | nil),
          required(:parse_primary) => (term() -> {:ok, term(), term()} | :fail),
          required(:build) => (fixity(), op_name(), [term()] -> term()),
          optional(:can_start_operand?) => (term() -> boolean())
        }

  @doc "An empty operator table."
  @spec new() :: table()
  def new, do: %{}

  @doc "Registers `op_name` as a prefix operator at `prec`."
  @spec prefix(table(), op_name(), non_neg_integer()) :: table()
  def prefix(table, op_name, prec), do: put_fixity(table, op_name, :prefix, prec)

  @doc "Registers `op_name` as an infix operator at `prec` with associativity `assoc` (default `:left`)."
  @spec infix(table(), op_name(), non_neg_integer(), assoc()) :: table()
  def infix(table, op_name, prec, assoc \\ :left),
    do: put_fixity(table, op_name, :infix, {prec, assoc})

  @doc "Registers `op_name` as a postfix operator at `prec`."
  @spec postfix(table(), op_name(), non_neg_integer()) :: table()
  def postfix(table, op_name, prec), do: put_fixity(table, op_name, :postfix, prec)

  defp put_fixity(table, op_name, kind, value),
    do: Map.update(table, op_name, %{kind => value}, &Map.put(&1, kind, value))

  @doc """
  Parses one expression starting at `pos`, only accepting an infix/postfix
  operator whose precedence is at least `min_prec` (default `0` -- pass
  a table entry's own precedence, bumped per associativity, on the
  recursive call that parses an operator's own operand).
  """
  @spec parse(table(), term(), callbacks(), non_neg_integer()) ::
          {:ok, term(), term()} | :fail
  def parse(table, pos, callbacks, min_prec \\ 0) do
    with {:ok, pos, left} <- parse_nud(table, pos, callbacks) do
      parse_led(table, pos, min_prec, left, callbacks)
    end
  end

  # "nud" (null denotation, Pratt's own terminology): what a token means
  # with no left operand yet -- either a registered prefix operator, or
  # a plain primary.
  defp parse_nud(table, pos, callbacks) do
    case callbacks.peek_op.(pos) do
      nil ->
        callbacks.parse_primary.(pos)

      {op_name, pos_after_op} ->
        case Map.get(table, op_name) do
          %{prefix: prec} ->
            with {:ok, pos, operand} <- parse(table, pos_after_op, callbacks, prec) do
              {:ok, pos, callbacks.build.(:prefix, op_name, [operand])}
            end

          _ ->
            callbacks.parse_primary.(pos)
        end
    end
  end

  # "led" (left denotation): what a token means once a left operand
  # already exists -- infix, postfix, or (precedence too low, or not an
  # operator at all) nothing, stopping the climb here.
  defp parse_led(table, pos, min_prec, left, callbacks) do
    case callbacks.peek_op.(pos) do
      nil ->
        {:ok, pos, left}

      {op_name, pos_after_op} ->
        case Map.get(table, op_name, %{}) do
          %{infix: {infix_prec, assoc}, postfix: postfix_prec} ->
            resolve_led_conflict(
              table,
              pos,
              pos_after_op,
              min_prec,
              left,
              callbacks,
              op_name,
              {infix_prec, assoc},
              postfix_prec
            )

          %{infix: {prec, assoc}} when prec >= min_prec ->
            apply_infix(table, pos_after_op, min_prec, left, callbacks, op_name, prec, assoc)

          %{postfix: prec} when prec >= min_prec ->
            apply_postfix(table, pos_after_op, min_prec, left, callbacks, op_name, prec)

          _ ->
            {:ok, pos, left}
        end
    end
  end

  defp resolve_led_conflict(
         table,
         pos,
         pos_after_op,
         min_prec,
         left,
         callbacks,
         op_name,
         {infix_prec, assoc},
         postfix_prec
       ) do
    infix_ok = infix_prec >= min_prec
    postfix_ok = postfix_prec >= min_prec

    cond do
      infix_ok and postfix_ok ->
        case choose_fixity(callbacks, pos_after_op, op_name) do
          :infix ->
            apply_infix(
              table,
              pos_after_op,
              min_prec,
              left,
              callbacks,
              op_name,
              infix_prec,
              assoc
            )

          :postfix ->
            apply_postfix(table, pos_after_op, min_prec, left, callbacks, op_name, postfix_prec)
        end

      infix_ok ->
        apply_infix(table, pos_after_op, min_prec, left, callbacks, op_name, infix_prec, assoc)

      postfix_ok ->
        apply_postfix(table, pos_after_op, min_prec, left, callbacks, op_name, postfix_prec)

      true ->
        {:ok, pos, left}
    end
  end

  defp choose_fixity(%{can_start_operand?: can_start_operand?}, pos_after_op, _op_name) do
    if can_start_operand?.(pos_after_op), do: :infix, else: :postfix
  end

  defp choose_fixity(_callbacks, _pos_after_op, op_name) do
    raise ArgumentError,
          "#{inspect(op_name)} is registered as both :infix and :postfix, which is " <>
            "ambiguous without a :can_start_operand? callback to tell them apart -- " <>
            "either avoid registering both fixities for the same operator, or pass " <>
            "can_start_operand? in callbacks"
  end

  defp apply_infix(table, pos_after_op, min_prec, left, callbacks, op_name, prec, assoc) do
    next_min = if assoc == :right, do: prec, else: prec + 1

    with {:ok, pos, right} <- parse(table, pos_after_op, callbacks, next_min) do
      parse_led(table, pos, min_prec, callbacks.build.(:infix, op_name, [left, right]), callbacks)
    end
  end

  defp apply_postfix(table, pos_after_op, min_prec, left, callbacks, op_name, _prec) do
    parse_led(
      table,
      pos_after_op,
      min_prec,
      callbacks.build.(:postfix, op_name, [left]),
      callbacks
    )
  end
end
