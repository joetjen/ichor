defmodule Ichor.Toolkit.TermWalkExampleTest do
  @moduledoc """
  Proves `Ichor.Toolkit.TermWalk` works outside Ichor's own logic-
  programming/type-inference domain entirely, via `Template`
  (`test/support/template.ex`).
  """

  use ExUnit.Case, async: true

  @template {:concat,
             [
               {:lit, "Hello, "},
               {:var, :name},
               {:lit, "! You are "},
               {:var, :age},
               {:lit, " years old."}
             ]}

  describe "variables/1 (fold/4)" do
    test "collects every referenced variable name, in a set" do
      assert Template.variables(@template) == MapSet.new([:name, :age])
    end

    test "a template with no variables has an empty set" do
      assert Template.variables({:lit, "just text"}) == MapSet.new()
    end

    test "the same variable referenced twice is still one entry" do
      template = {:concat, [{:var, :x}, {:lit, " and "}, {:var, :x}]}
      assert Template.variables(template) == MapSet.new([:x])
    end
  end

  describe "render/2 (rewrite/3)" do
    test "substitutes every variable and flattens to a string" do
      assert Template.render(@template, %{name: "Ada", age: "36"}) ==
               "Hello, Ada! You are 36 years old."
    end

    test "a template with no variables renders unchanged" do
      assert Template.render({:lit, "just text"}, %{}) == "just text"
    end

    test "the same variable substituted twice uses the same value both times" do
      template = {:concat, [{:var, :x}, {:lit, "-"}, {:var, :x}]}
      assert Template.render(template, %{x: "42"}) == "42-42"
    end

    test "a missing binding fails loudly rather than rendering a blank" do
      assert_raise KeyError, fn -> Template.render(@template, %{name: "Ada"}) end
    end
  end
end
