defmodule RecordImporter do
  @moduledoc """
  A worked example for `Ichor.Toolkit.Result`, deliberately unrelated to
  grammars or compilers: imports a table of raw string rows into a map
  of typed records keyed by a chosen field.

  Two distinct uses of the toolkit, at two different nesting levels:
  `map_ok/3` parses each row's cells left-to-right, threading a column
  index purely so a failure can name *which* column broke
  (`parse_row/3`), and again one level up to parse every row in order,
  threading a row number for the same reason (`import/3`); `reduce_ok/3`
  then folds the parsed records into one map, rejecting a repeated key
  -- the same "collect into a map, catch duplicates" shape Ichor's own
  grammar-family `Actions` modules use for their rule tables
  (`build_ruleset/1`), just in an unrelated domain.
  """

  alias Ichor.Toolkit.Result

  @type type :: :string | :integer | :float
  @type schema :: [{atom(), type()}]

  @doc """
  Imports `rows` (each a list of raw strings, one per `schema` column,
  in row order) into a map keyed by `key_field`'s parsed value. Fails on
  the first cell that doesn't parse as its column's declared type, or on
  a repeated key.
  """
  @spec import(schema(), atom(), [[String.t()]]) ::
          {:ok, %{term() => map()}} | {:error, String.t()}
  def import(schema, key_field, rows) do
    with {:ok, records, _row_count} <- Result.map_ok(rows, 1, &parse_row(&1, schema, &2)) do
      Result.reduce_ok(records, %{}, fn record, acc ->
        key = Map.fetch!(record, key_field)

        if Map.has_key?(acc, key) do
          {:error, "duplicate #{key_field}: #{inspect(key)}"}
        else
          {:ok, Map.put(acc, key, record)}
        end
      end)
    end
  end

  defp parse_row(cells, schema, row_num) do
    case Result.map_ok(Enum.zip(cells, schema), 1, &parse_cell/2) do
      {:ok, fields, _col_count} -> {:ok, Map.new(fields), row_num + 1}
      {:error, reason} -> {:error, "row #{row_num}: #{reason}"}
    end
  end

  defp parse_cell({raw, {field, type}}, col) do
    case parse_value(raw, type) do
      {:ok, value} -> {:ok, {field, value}, col + 1}
      :error -> {:error, "column #{col} (#{field}): #{inspect(raw)} is not a valid #{type}"}
    end
  end

  defp parse_value(raw, :string), do: {:ok, raw}

  defp parse_value(raw, :integer) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_value(raw, :float) do
    case Float.parse(raw) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end
end
