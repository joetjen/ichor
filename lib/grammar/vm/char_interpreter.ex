defmodule Grammar.VM.CharInterpreter do
  @moduledoc """
  Runs a `Grammar.VM.CharCompiler`-produced program against raw input
  text -- the machine `Grammar.VM.Tokenizer` uses to test one token at a
  given starting position.

  Each backtrack (choice-point) entry snapshots the *call* stack
  alongside input position, not just position -- a failed nested `:call`
  (e.g. retrying a `Star` loop's body one time too many) unwinds via the
  backtrack mechanism, jumping straight to some choice point's target
  without ever executing that call's own `:return`. Without restoring the
  call stack too, that call's return address is orphaned on it, and gets
  popped at the wrong time later, corrupting execution. This is a
  standard, if easy to miss, requirement for any PEG bytecode VM in this
  LPeg-derived style.

  `Star`'s loop-back uses `:test_progress`, not plain `:commit` -- a
  runtime guard against a body that matches without consuming anything
  (see `Grammar.VM.Compiler`'s docs on why this can't be left to
  `Grammar.Analysis`'s static empty-repetition check alone).
  """

  @doc """
  Attempts to match `entry` starting at `input`. On success, returns the
  unconsumed remainder (its byte-size difference from `input` is how much
  was matched -- exactly what maximal munch needs to compare candidates).
  """
  @spec run(tuple(), non_neg_integer(), String.t()) :: {:ok, String.t()} | :fail
  def run(instructions, entry, input) do
    loop(instructions, entry, input, [], [:done])
  end

  defp loop(instrs, ip, input, backtrack, calls) do
    case elem(instrs, ip) do
      {:lit, v} ->
        if String.starts_with?(input, v) do
          rest = binary_part(input, byte_size(v), byte_size(input) - byte_size(v))
          loop(instrs, ip + 1, rest, backtrack, calls)
        else
          fail(instrs, backtrack)
        end

      {:set, ranges} ->
        case input do
          <<c::utf8, rest::binary>> ->
            if Enum.any?(ranges, fn {a, b} -> c in a..b end) do
              loop(instrs, ip + 1, rest, backtrack, calls)
            else
              fail(instrs, backtrack)
            end

          _ ->
            fail(instrs, backtrack)
        end

      {:any} ->
        case input do
          <<_c::utf8, rest::binary>> -> loop(instrs, ip + 1, rest, backtrack, calls)
          _ -> fail(instrs, backtrack)
        end

      {:jmp, target} ->
        loop(instrs, target, input, backtrack, calls)

      # Push a choice point: if anything fails before the matching
      # `:commit`, execution resumes at `target` with `input`/`calls`
      # rolled back to right now.
      {:choice, target} ->
        loop(instrs, ip + 1, input, [{input, calls, target} | backtrack], calls)

      # The alternative we just chose succeeded -- drop the choice point
      # `:choice` pushed and jump past the untaken alternative(s).
      {:commit, target} ->
        [_ | rest_bt] = backtrack
        loop(instrs, target, input, rest_bt, calls)

      # Star's loop-back: only re-enter the body if the previous iteration
      # actually consumed input. Without this, a body that can match empty
      # (nullable) would loop forever instead of exiting the repetition.
      {:test_progress, loop_target} ->
        [{saved_input, _saved_calls, _} | rest_bt] = backtrack

        if input == saved_input do
          loop(instrs, ip + 1, input, rest_bt, calls)
        else
          loop(instrs, loop_target, input, rest_bt, calls)
        end

      # Used by `AndPred`: succeed at `target`, but rewind input (and the
      # call stack) to where the lookahead started, since a positive
      # lookahead must never consume.
      {:back_commit, target} ->
        [{saved_input, saved_calls, _} | rest_bt] = backtrack
        loop(instrs, target, saved_input, rest_bt, saved_calls)

      {:call, target} ->
        loop(instrs, target, input, backtrack, [ip + 1 | calls])

      {:return} ->
        case calls do
          [:done] -> {:ok, input}
          [ret | rest_calls] -> loop(instrs, ret, input, backtrack, rest_calls)
        end

      {:fail} ->
        fail(instrs, backtrack)

      # Used by `NotPred`: unconditionally fail even if the wrapped
      # expression just succeeded, discarding the choice point that
      # success would otherwise have left behind.
      {:fail_twice} ->
        case backtrack do
          [_ | rest_bt] -> fail(instrs, rest_bt)
          [] -> :fail
        end
    end
  end

  defp fail(_instrs, []), do: :fail

  # Backtrack to the most recent choice point, restoring input position
  # and the call stack exactly as they were when `:choice` pushed it.
  defp fail(instrs, [{saved_input, saved_calls, target} | rest_bt]) do
    loop(instrs, target, saved_input, rest_bt, saved_calls)
  end
end
