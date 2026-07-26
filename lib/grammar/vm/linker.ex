defmodule Grammar.VM.Linker do
  @moduledoc """
  Turns `[{name, ops}]` -- one label-relative op list per token or rule,
  as produced by `Grammar.VM.Compiler` -- into a single linked
  `Grammar.VM.Program`.

  Each op list may contain two kinds of placeholder alongside real
  instructions: `{:label, n}` (a jump target local to that op list) and
  the real instructions `{:jmp, n}` / `{:choice, n}` / `{:commit, n}` /
  `{:back_commit, n}` / `{:test_progress, n}` that reference one.
  `{:call, name}` is a *different*
  kind of forward reference -- to another token/rule's own entry point,
  by name, resolved against every op list at once (that's the whole
  reason linking happens globally instead of per-name: `:call` needs to
  reach targets compiled by a different, unrelated `compile/1` call).
  """

  @doc """
  Concatenates every `{name, ops}` pair (in the given order) into one
  instruction tuple, resolving local labels and `:call` targets alike in
  a single position-tracking pass.
  """
  @spec link([{atom(), [term()]}]) :: Grammar.VM.Program.t()
  def link(named_ops) do
    tagged = Enum.flat_map(named_ops, fn {name, ops} -> [{:entry, name} | ops] end)

    {reversed_ops, labels, entries, _index} =
      Enum.reduce(tagged, {[], %{}, %{}, 0}, fn
        {:label, n}, {ops, labels, entries, index} ->
          {ops, Map.put(labels, n, index), entries, index}

        {:entry, name}, {ops, labels, entries, index} ->
          {ops, labels, Map.put(entries, name, index), index}

        instr, {ops, labels, entries, index} ->
          {[instr | ops], labels, entries, index + 1}
      end)

    instructions =
      reversed_ops
      |> Enum.reverse()
      |> Enum.map(&resolve(&1, labels, entries))
      |> List.to_tuple()

    %Grammar.VM.Program{instructions: instructions, entry_points: entries}
  end

  defp resolve({:jmp, l}, labels, _entries), do: {:jmp, Map.fetch!(labels, l)}
  defp resolve({:choice, l}, labels, _entries), do: {:choice, Map.fetch!(labels, l)}
  defp resolve({:commit, l}, labels, _entries), do: {:commit, Map.fetch!(labels, l)}
  defp resolve({:back_commit, l}, labels, _entries), do: {:back_commit, Map.fetch!(labels, l)}
  defp resolve({:test_progress, l}, labels, _entries), do: {:test_progress, Map.fetch!(labels, l)}
  defp resolve({:call, name}, _labels, entries), do: {:call, Map.fetch!(entries, name)}
  defp resolve(other, _labels, _entries), do: other
end
