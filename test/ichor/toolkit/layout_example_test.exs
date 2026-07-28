defmodule Ichor.Toolkit.LayoutExampleTest do
  @moduledoc """
  Proves `Ichor.Toolkit.Layout` works outside Ichor's own grammar/token
  domain entirely, via `OutlineParser` (`test/support/outline_parser.ex`).
  """

  use ExUnit.Case, async: true

  test "a flat outline with no nesting" do
    text = """
    a
    b
    c
    """

    assert OutlineParser.parse(text) == {:ok, [{"a", []}, {"b", []}, {"c", []}]}
  end

  test "one level of nesting, closed automatically at end of input" do
    text = """
    a
      b
      c
    """

    assert OutlineParser.parse(text) == {:ok, [{"a", [{"b", []}, {"c", []}]}]}
  end

  test "nested, then dedented back to a sibling, then fully back to the top" do
    text = """
    a
      b
      c
        d
      e
    f
    """

    assert OutlineParser.parse(text) ==
             {:ok,
              [
                {"a", [{"b", []}, {"c", [{"d", []}]}, {"e", []}]},
                {"f", []}
              ]}
  end

  test "mismatched indentation is a reported error, not a crash or a silent misparse" do
    text = """
    a
        b
      c
    """

    assert {:error, {:inconsistent_dedent, 2, [4, 0]}} = OutlineParser.parse(text)
  end
end
