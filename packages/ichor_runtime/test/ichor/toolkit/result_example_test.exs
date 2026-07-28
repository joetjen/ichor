defmodule Ichor.Toolkit.ResultExampleTest do
  @moduledoc """
  Proves `Ichor.Toolkit.Result`'s helpers work outside Ichor's own
  compiler internals entirely, via `RecordImporter`
  (`test/support/record_importer.ex`) -- a tiny CSV-shaped record
  importer with no grammar/compiler concepts anywhere in it.
  """

  use ExUnit.Case, async: true

  @schema [{:id, :integer}, {:name, :string}, {:score, :float}]

  describe "successful import" do
    test "parses every row and keys the result by the chosen field" do
      rows = [["1", "alice", "9.5"], ["2", "bob", "7.25"]]

      assert {:ok, records} = RecordImporter.import(@schema, :id, rows)

      assert records == %{
               1 => %{id: 1, name: "alice", score: 9.5},
               2 => %{id: 2, name: "bob", score: 7.25}
             }
    end

    test "an empty table imports to an empty map" do
      assert RecordImporter.import(@schema, :id, []) == {:ok, %{}}
    end
  end

  describe "a cell that fails to parse, via map_ok/3's threaded column index" do
    test "names the row and column of the first bad cell" do
      rows = [["1", "alice", "9.5"], ["nope", "bob", "7.25"]]

      assert {:error, message} = RecordImporter.import(@schema, :id, rows)
      assert message =~ "row 2"
      assert message =~ "column 1"
      assert message =~ "id"
    end

    test "stops at the first failure -- a later row's own error never surfaces" do
      rows = [["x", "alice", "9.5"], ["y", "bob", "not-a-float"]]

      assert {:error, message} = RecordImporter.import(@schema, :id, rows)
      assert message =~ "row 1"
    end
  end

  describe "a repeated key, via reduce_ok/3" do
    test "the second row with the same id is rejected" do
      rows = [["1", "alice", "9.5"], ["1", "bob", "7.25"]]

      assert {:error, message} = RecordImporter.import(@schema, :id, rows)
      assert message =~ "duplicate id"
      assert message =~ "1"
    end
  end
end
