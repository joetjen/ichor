defmodule Yaml.Materialize do
  @moduledoc """
  A "materialize pass" over the plain `Ichor.Node` tree the `4.3 yaml`
  grammar's default fallback already builds with *zero* custom
  `Ichor.Actions` callbacks -- turning that generic "one `%Ichor.Node{}`
  per matched rule" shape into the actual nested map/list a caller wants
  (`%{"name" => "ichor", "tags" => ["grammar", "parser"]}`, not a tree
  of `%Ichor.Node{rule: :mapping, ...}` wrappers).

  Deliberately not a `Ichor.Actions` callback module: unlike LISP, this
  grammar needs no custom evaluation semantics at all, just a parse.
  This is a separate, ordinary post-processing step over whatever
  `Grammar.VM.run/4` already returned.
  """

  @doc "Converts a `4.3 yaml` grammar's default-fallback parse result into a plain map/list/string."
  @spec run(term()) :: term()
  def run(%Ichor.Node{rule: :document, captures: captures}), do: run(document_value(captures))
  def run(%Ichor.Node{rule: :mapping, captures: %{pair: pairs}}), do: Map.new(pairs, &pair/1)
  def run(%Ichor.Node{rule: :sequence, captures: %{item: items}}), do: Enum.map(items, &item/1)
  def run(text) when is_binary(text), do: text

  defp document_value(%{root_mapping: value}), do: value
  defp document_value(%{root_sequence: value}), do: value
  defp document_value(%{scalar_doc: value}), do: value

  defp pair(%Ichor.Node{rule: :pair, captures: %{SCALAR: key} = captures}),
    do: {key, run(pair_value(captures))}

  defp pair_value(%{inline_value: value}), do: value
  defp pair_value(%{block_value: value}), do: value

  defp item(%Ichor.Node{rule: :item, captures: captures}), do: run(item_value(captures))

  defp item_value(%{scalar_doc: value}), do: value
  defp item_value(%{root_mapping: value}), do: value
end
