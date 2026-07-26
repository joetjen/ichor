defmodule Ichor.ErrorTest do
  use ExUnit.Case, async: true
  doctest Ichor.Error

  alias Ichor.Error

  test "context_lines is a caret-annotated snippet pointing at line/column" do
    error =
      Error.new(
        message: "expected ')'",
        stage: :parser,
        line: 1,
        column: 8,
        source: "(2 + 3"
      )

    assert error.context_lines == "1 | (2 + 3\n  |        ^"
  end

  test "picks the right line out of multi-line source" do
    source = "line one\nline two\nline three"

    error = Error.new(message: "boom", line: 2, column: 6, source: source)

    assert error.context_lines == "2 | line two\n  |      ^"
  end

  test "gutter width matches the line number's own digit count" do
    source = Enum.map_join(1..12, "\n", &"line #{&1}")

    error = Error.new(message: "boom", line: 12, column: 3, source: source)

    assert error.context_lines == "12 | line 12\n   |   ^"
  end

  test "context_lines is nil when source or line is missing" do
    assert Error.new(message: "boom").context_lines == nil
    assert Error.new(message: "boom", source: "abc").context_lines == nil
    assert Error.new(message: "boom", line: 1).context_lines == nil
  end

  test "context_lines is nil when line is out of range" do
    error = Error.new(message: "boom", line: 99, column: 1, source: "only one line")

    assert error.context_lines == nil
  end

  test "an explicit :context_lines is used as-is, without needing :source" do
    error = Error.new(message: "boom", context_lines: "pre-rendered snippet")

    assert error.context_lines == "pre-rendered snippet"
  end

  test "format/1 renders file:line:column, the message, then the snippet" do
    error =
      Error.new(
        message: "expected ')'",
        stage: :parser,
        file: "calc.aether",
        line: 1,
        column: 8,
        source: "(2 + 3"
      )

    assert Error.format(error) == "calc.aether:1:8: expected ')'\n1 | (2 + 3\n  |        ^"
  end

  test "format/1 degrades gracefully with no file, no location, no snippet" do
    error = Error.new(message: "boom")

    assert Error.format(error) == "boom"
  end

  test "the struct itself only has the eight documented fields" do
    assert Map.keys(%Error{}) |> Enum.reject(&(&1 == :__struct__)) |> Enum.sort() ==
             [:column, :context_lines, :expected, :file, :found, :line, :message, :stage]
  end
end
