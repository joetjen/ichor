defmodule Grammar.VM.TokenInterpreter do
  @moduledoc """
  Runs a `Grammar.VM.RuleCompiler`-produced program against a lexed token
  stream -- the machine `Grammar.VM` uses for the parser stage.

  Alongside recognition, it builds the raw capture tree `Ichor.Actions`
  needs: each rule invocation gets its own "frame" (a
  `%{pending: [...], captures: []}` accumulator), pushed on `:call` and
  popped on `:return`, populated by the `:cap_start`/`:cap_end` pairs
  `Grammar.VM.RuleCompiler` brackets every capture (implicit or explicit)
  with. `captures` is an ordered list, not a map -- list order is the
  one thing Elixir actually guarantees, which is what lets
  `Ichor.Actions.eval_all/2` evaluate sibling captures in true source
  order instead of trusting a plain map's own (cross-OTP-version-
  unstable) iteration order; `merge_capture/3` mirrors
  `Grammar.Native.Runtime.Parser.merge_one/3` (from `ichor_runtime`)
  exactly, for parity with the native backend.

  Structurally the same backtracking discipline as
  `Grammar.VM.CharInterpreter` (including snapshotting the call stack in
  every choice point, for the same reason -- see that module's docs),
  plus two more things to snapshot/restore: the capture-in-progress
  `frame` (a failed alternative's partial captures must never leak into
  a sibling alternative that goes on to succeed) and the `@indent`/
  `@samecol` reference-column stack.

  `Star`'s loop-back uses `:test_progress`, not plain `:commit` -- a
  runtime guard against a body that matches without consuming anything
  (see `Grammar.VM.Compiler`'s docs on why this can't be left to
  `Grammar.Analysis`'s static empty-repetition check alone).

  `context` is threaded through every instruction purely so `{:custom,
  ...}` (a `Grammar.IR.Custom` `@native(...)` node) can hand it to
  `c:Ichor.CustomRule.match/4` -- every other instruction ignores it. It's
  read-only here: matching never produces a *new* context, only
  `Ichor.Actions.evaluate/5` does that, between top-level forms.
  """

  alias Grammar.VM.Token
  alias Ichor.Capture

  @type raw_capture :: Capture.node_t()

  @type rule_matcher :: (tuple(), non_neg_integer() ->
                           {:ok, non_neg_integer(), raw_capture()} | :fail)

  @doc """
  Attempts to match `entry` against `stream` (a tuple of `Grammar.VM.Token`,
  for O(1) indexed access) starting at position 0. On success, returns the
  first unconsumed stream index and the matched rule's own raw captures
  list -- the caller decides whether the index means "matched everything".
  """
  @spec run(tuple(), non_neg_integer(), tuple(), term()) ::
          {:ok, non_neg_integer(), Capture.raw_captures()} | :fail
  def run(instructions, entry, stream, context \\ nil),
    do: run_from(instructions, entry, stream, 0, context)

  @doc "Like `run/4`, but starts at `start_pos` instead of 0 -- for matching one of *several* top-level occurrences in the same stream (`Grammar.VM.run_sequence/4`)."
  @spec run_from(tuple(), non_neg_integer(), tuple(), non_neg_integer(), term()) ::
          {:ok, non_neg_integer(), Capture.raw_captures()} | :fail
  def run_from(instructions, entry, stream, start_pos, context \\ nil) do
    loop(
      instructions,
      entry,
      start_pos,
      stream,
      [0],
      [],
      [{:done, nil}],
      fresh_frame(),
      nil,
      context
    )
  end

  defp fresh_frame, do: %{pending: [], captures: []}

  defp loop(instrs, ip, pos, stream, ref_stack, backtrack, calls, frame, last_result, context) do
    case elem(instrs, ip) do
      {:token, name} ->
        case at(stream, pos) do
          %Token{name: ^name} ->
            loop(
              instrs,
              ip + 1,
              pos + 1,
              stream,
              ref_stack,
              backtrack,
              calls,
              frame,
              last_result,
              context
            )

          _ ->
            fail(instrs, backtrack, stream, context)
        end

      {:cap_start, name, kind, ref_name} ->
        pending = [{name, kind, ref_name, pos} | frame.pending]

        loop(
          instrs,
          ip + 1,
          pos,
          stream,
          ref_stack,
          backtrack,
          calls,
          %{frame | pending: pending},
          last_result,
          context
        )

      {:cap_end, name} ->
        [{^name, kind, ref_name, start_pos} | rest_pending] = frame.pending
        raw = build_raw_capture(kind, ref_name, stream, start_pos, pos, last_result)
        captures = merge_capture(frame.captures, name, raw)
        new_frame = %{frame | pending: rest_pending, captures: captures}

        loop(
          instrs,
          ip + 1,
          pos,
          stream,
          ref_stack,
          backtrack,
          calls,
          new_frame,
          last_result,
          context
        )

      {:indent_enter} ->
        case at(stream, pos) do
          nil ->
            fail(instrs, backtrack, stream, context)

          %Token{column: col} ->
            [ref | _] = ref_stack

            if col > ref do
              loop(
                instrs,
                ip + 1,
                pos,
                stream,
                [col | ref_stack],
                backtrack,
                calls,
                frame,
                last_result,
                context
              )
            else
              fail(instrs, backtrack, stream, context)
            end
        end

      {:indent_exit} ->
        [_ | rest_ref] = ref_stack
        loop(instrs, ip + 1, pos, stream, rest_ref, backtrack, calls, frame, last_result, context)

      {:samecol_check} ->
        case at(stream, pos) do
          nil ->
            fail(instrs, backtrack, stream, context)

          %Token{column: col} ->
            [ref | _] = ref_stack

            if col == ref do
              loop(
                instrs,
                ip + 1,
                pos,
                stream,
                ref_stack,
                backtrack,
                calls,
                frame,
                last_result,
                context
              )
            else
              fail(instrs, backtrack, stream, context)
            end
        end

      {:jmp, target} ->
        loop(
          instrs,
          target,
          pos,
          stream,
          ref_stack,
          backtrack,
          calls,
          frame,
          last_result,
          context
        )

      {:choice, target} ->
        entry = {pos, ref_stack, frame, calls, target}

        loop(
          instrs,
          ip + 1,
          pos,
          stream,
          ref_stack,
          [entry | backtrack],
          calls,
          frame,
          last_result,
          context
        )

      {:commit, target} ->
        [_ | rest_bt] = backtrack
        loop(instrs, target, pos, stream, ref_stack, rest_bt, calls, frame, last_result, context)

      {:test_progress, loop_target} ->
        [{saved_pos, _, _, _, _} | rest_bt] = backtrack

        if pos == saved_pos do
          loop(
            instrs,
            ip + 1,
            pos,
            stream,
            ref_stack,
            rest_bt,
            calls,
            frame,
            last_result,
            context
          )
        else
          loop(
            instrs,
            loop_target,
            pos,
            stream,
            ref_stack,
            rest_bt,
            calls,
            frame,
            last_result,
            context
          )
        end

      {:back_commit, target} ->
        [{saved_pos, saved_ref, saved_frame, saved_calls, _} | rest_bt] = backtrack

        loop(
          instrs,
          target,
          saved_pos,
          stream,
          saved_ref,
          rest_bt,
          saved_calls,
          saved_frame,
          last_result,
          context
        )

      # Entering a rule call: save the return address *and* the caller's
      # in-progress frame together, then start the callee with a fresh
      # one -- the callee's captures must never mix with the caller's.
      {:call, target} ->
        loop(
          instrs,
          target,
          pos,
          stream,
          ref_stack,
          backtrack,
          [{ip + 1, frame} | calls],
          fresh_frame(),
          last_result,
          context
        )

      # Returning from a rule call: restore the caller's own frame (their
      # `:cap_end` may still be pending), and hand them the callee's
      # finished captures as `last_result` -- that's what lets a
      # directly-captured `RuleRef` dispatch to the callee's own action
      # later, instead of just capturing matched text.
      {:return} ->
        case calls do
          [{:done, _}] ->
            {:ok, pos, frame.captures}

          [{ret, parent_frame} | rest_calls] ->
            loop(
              instrs,
              ret,
              pos,
              stream,
              ref_stack,
              backtrack,
              rest_calls,
              parent_frame,
              frame.captures,
              context
            )
        end

      # `@native(...)`: hands off to hand-written Elixir code instead of
      # compiled instructions. `rule_matchers` is built fresh per call so
      # each closure captures this exact `context` snapshot -- match never
      # mutates it, so rebuilding it here (rather than caching it at
      # compile time) is just for simplicity, not correctness.
      {:custom, module, function, dep_entries} ->
        rule_matchers = build_rule_matchers(instrs, dep_entries, context)

        case apply(module, function, [stream, pos, context, rule_matchers]) do
          {:ok, new_pos, capture} ->
            loop(
              instrs,
              ip + 1,
              new_pos,
              stream,
              ref_stack,
              backtrack,
              calls,
              frame,
              capture,
              context
            )

          :fail ->
            fail(instrs, backtrack, stream, context)
        end

      {:fail} ->
        fail(instrs, backtrack, stream, context)

      {:fail_twice} ->
        case backtrack do
          [_ | rest_bt] -> fail(instrs, rest_bt, stream, context)
          [] -> :fail
        end
    end
  end

  defp build_rule_matchers(instrs, dep_entries, context) do
    Map.new(dep_entries, fn {name, entry} ->
      {name,
       fn stream, pos ->
         case run_from(instrs, entry, stream, pos, context) do
           {:ok, new_pos, caps} -> {:ok, new_pos, {:rule, name, caps}}
           :fail -> :fail
         end
       end}
    end)
  end

  # A `Grammar.IR.CustomLexeme`-matched token can carry its own capture
  # override (a string-interpolation token's embedded expressions, say)
  # instead of the usual flat `{:token, name, text}` -- built once, back
  # in `Grammar.VM.Tokenizer`, rather than re-derived here.
  defp build_raw_capture(:token, ref_name, stream, start_pos, _end_pos, _last_result) do
    case elem(stream, start_pos) do
      %Token{capture: nil, text: text} -> {:token, ref_name, text}
      %Token{capture: capture} -> capture
    end
  end

  defp build_raw_capture(:rule, ref_name, _stream, _start_pos, _end_pos, last_result) do
    {:rule, ref_name, last_result}
  end

  defp build_raw_capture(:custom, _ref_name, _stream, _start_pos, _end_pos, last_result),
    do: last_result

  defp build_raw_capture(:text, _ref_name, stream, start_pos, end_pos, _last_result) do
    {:text, concat_text(stream, start_pos, end_pos)}
  end

  defp concat_text(stream, start_pos, end_pos) do
    Enum.map_join(start_pos..(end_pos - 1)//1, "", fn i -> elem(stream, i).text end)
  end

  # First occurrence of `name` in this frame is appended at the end (landing
  # at its first-occurrence position, as `raw`, unwrapped); a second
  # occurrence promotes it to a list, in place, not moving it; a third+
  # appends to that list, in place -- so a capture inside a `Star`/`Plus`
  # naturally ends up as a list without the caller having to know in advance
  # how many times it'll match. Mirrors `Grammar.Native.Runtime.Parser`'s
  # own private `merge_one`/`as_list` helpers (from `ichor_runtime`) exactly.
  defp merge_capture(captures, name, raw) do
    case List.keyfind(captures, name, 0) do
      nil -> captures ++ [{name, raw}]
      {^name, existing} -> List.keyreplace(captures, name, 0, {name, as_list(existing) ++ [raw]})
    end
  end

  defp as_list(v) when is_list(v), do: v
  defp as_list(v), do: [v]

  defp at(stream, pos) when pos < tuple_size(stream), do: elem(stream, pos)
  defp at(_stream, _pos), do: nil

  defp fail(_instrs, [], _stream, _context), do: :fail

  defp fail(
         instrs,
         [{saved_pos, saved_ref, saved_frame, saved_calls, target} | rest_bt],
         stream,
         context
       ) do
    loop(
      instrs,
      target,
      saved_pos,
      stream,
      saved_ref,
      rest_bt,
      saved_calls,
      saved_frame,
      nil,
      context
    )
  end
end
