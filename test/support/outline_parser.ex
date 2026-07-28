defmodule OutlineParser do
  @moduledoc """
  A worked example for `Ichor.Toolkit.Layout`, deliberately unrelated to
  grammars or compilers: parses an indentation-based outline (each line
  more indented than the one above becomes its child) into a nested
  tree, using `Layout.step/2`/`close/1` to turn each line's leading-space
  count into a flat `:indent`/`:dedent`/`{:line, text}` event stream,
  then a small stack-based fold turns that into `{text, children}`
  nodes -- the classic off-side-rule algorithm, applied outside any
  grammar/parser context at all.
  """

  alias Ichor.Toolkit.Layout

  @spec parse(String.t()) :: {:ok, [{String.t(), list()}]} | {:error, term()}
  def parse(text) do
    lines =
      text
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        stripped = String.trim_leading(line)
        {String.length(line) - String.length(stripped), stripped}
      end)

    with {:ok, events} <- events(lines) do
      {:ok, build_tree(events)}
    end
  end

  defp events(lines) do
    case Enum.reduce_while(lines, {[], [0]}, fn {width, text}, {acc, stack} ->
           case Layout.step(width, stack) do
             {:ok, markers, new_stack} ->
               {:cont, {acc ++ markers ++ [{:line, text}], new_stack}}

             {:error, reason} ->
               {:halt, {:error, reason}}
           end
         end) do
      {:error, _} = err -> err
      {events, stack} -> {:ok, events ++ Layout.close(stack)}
    end
  end

  defp build_tree(events) do
    [roots] = Enum.reduce(events, [[]], &apply_event/2)
    roots
  end

  defp apply_event({:line, text}, [top | rest]), do: [top ++ [{text, []}] | rest]
  defp apply_event(:indent, stack), do: [[] | stack]

  defp apply_event(:dedent, [finished, parent | rest]) do
    {last_text, []} = List.last(parent)
    updated_parent = List.replace_at(parent, -1, {last_text, finished})
    [updated_parent | rest]
  end
end
