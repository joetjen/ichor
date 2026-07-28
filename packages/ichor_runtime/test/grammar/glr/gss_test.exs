defmodule Grammar.GLR.GSSTest do
  use ExUnit.Case, async: true

  alias Grammar.GLR.GSS

  test "new/0 starts with no edges" do
    assert GSS.new() == %GSS{edges: %{}}
  end

  test "add_edge/5 is idempotent for an identical edge" do
    gss = GSS.new() |> GSS.add_edge({0, 0}, {1, 1}, "tok", [])
    gss2 = GSS.add_edge(gss, {0, 0}, {1, 1}, "tok", [])
    assert gss == gss2
  end

  test "incoming/2 lists every edge landing on a node" do
    gss =
      GSS.new()
      |> GSS.add_edge({0, 0}, {1, 1}, "a", [])
      |> GSS.add_edge({2, 0}, {1, 1}, "b", [])

    edges = GSS.incoming(gss, {1, 1})
    assert length(edges) == 2
    assert {{0, 0}, "a", []} in edges
    assert {{2, 0}, "b", []} in edges
  end

  test "paths/3 walks k edges backward, collecting each distinct derivation" do
    gss =
      GSS.new()
      |> GSS.add_edge({0, 0}, {1, 1}, "a", [])
      |> GSS.add_edge({1, 1}, {2, 2}, "b", [])

    assert [{{0, 0}, [{"a", 0, 1}, {"b", 1, 2}], []}] = GSS.paths(gss, {2, 2}, 2)
  end

  test "paths/3 with k=0 returns the node itself, no entries consumed" do
    assert [{{5, 5}, [], []}] = GSS.paths(GSS.new(), {5, 5}, 0)
  end
end
