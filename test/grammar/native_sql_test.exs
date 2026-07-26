defmodule Grammar.Native.SQLTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp vm_grammar do
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
    {:ok, grammar: vm_grammar(), ctx: %{tables: %{"users" => @users}}}
  end

  describe "run/2 parity with the VM backend (@case_insensitive)" do
    for source <- [
          "select id, name from users where id = 42",
          "SELECT id, name FROM users WHERE id = 42",
          "SELECT * FROM users",
          "select name from users",
          "select * from users where name = 'bob'",
          "select * from users where id != 1",
          "select * from users where id <= 1",
          "select * from users where id >= 42",
          "select * from users where id < 2",
          "select * from users where id > 2"
        ] do
      test "#{inspect(source)}", %{grammar: g, ctx: ctx} do
        source = unquote(source)
        assert Native.SQL.run(source, ctx) == Grammar.VM.run(g, source, SQL.Actions, ctx)
      end
    end
  end

  test "a bad grammar/action mismatch yields a Ichor.Error on native too, not a crash", %{
    ctx: ctx
  } do
    assert {:error, %Ichor.Error{}} = Native.SQL.run("select from users", ctx)
  end
end
