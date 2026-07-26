defmodule SQL.ActionsTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.5 sql"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  @users [
    %{"id" => 1, "name" => "alice"},
    %{"id" => 2, "name" => "bob"},
    %{"id" => 42, "name" => "carol"}
  ]

  setup do
    {:ok, grammar: grammar(), ctx: %{tables: %{"users" => @users}}}
  end

  defp run(grammar, ctx, source), do: Grammar.VM.run(grammar, source, SQL.Actions, ctx)

  describe "the sql worked example" do
    test "lowercase keywords still match despite @case_insensitive", %{grammar: g, ctx: ctx} do
      assert {:ok, [%{"id" => 42, "name" => "carol"}]} =
               run(g, ctx, "select id, name from users where id = 42")
    end

    test "shouted keywords also match", %{grammar: g, ctx: ctx} do
      assert {:ok, [%{"id" => 42, "name" => "carol"}]} =
               run(g, ctx, "SELECT id, name FROM users WHERE id = 42")
    end
  end

  describe "column projection" do
    test "* returns every field, unfiltered", %{grammar: g, ctx: ctx} do
      assert {:ok, @users} == run(g, ctx, "SELECT * FROM users")
    end

    test "a single named column projects just that field", %{grammar: g, ctx: ctx} do
      assert {:ok, [%{"name" => "alice"}, %{"name" => "bob"}, %{"name" => "carol"}]} =
               run(g, ctx, "select name from users")
    end
  end

  describe "comparison operators" do
    test "=", %{grammar: g, ctx: ctx} do
      assert {:ok, [%{"id" => 2, "name" => "bob"}]} =
               run(g, ctx, "select * from users where name = 'bob'")
    end

    test "!=", %{grammar: g, ctx: ctx} do
      assert {:ok, rows} = run(g, ctx, "select * from users where id != 1")
      assert length(rows) == 2
      refute Enum.any?(rows, &(&1["id"] == 1))
    end

    test "<=, >=, <, >", %{grammar: g, ctx: ctx} do
      assert {:ok, [%{"id" => 1, "name" => "alice"}]} =
               run(g, ctx, "select * from users where id <= 1")

      assert {:ok, [%{"id" => 42, "name" => "carol"}]} =
               run(g, ctx, "select * from users where id >= 42")

      assert {:ok, [%{"id" => 1, "name" => "alice"}]} =
               run(g, ctx, "select * from users where id < 2")

      assert {:ok, [%{"id" => 42, "name" => "carol"}]} =
               run(g, ctx, "select * from users where id > 2")
    end
  end

  describe "no where_clause" do
    test "all rows pass through, unfiltered", %{grammar: g, ctx: ctx} do
      assert {:ok, @users} == run(g, ctx, "select * from users")
    end
  end

  describe "a bad grammar/action mismatch" do
    test "yields a Ichor.Error, not a crash", %{grammar: g, ctx: ctx} do
      assert {:error, %Ichor.Error{}} = run(g, ctx, "select from users")
    end
  end
end
