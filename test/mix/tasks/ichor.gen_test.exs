defmodule Mix.Tasks.Ichor.GenTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  test "writes a compilable module that runs correctly for a peg grammar", %{tmp_dir: tmp_dir} do
    grammar_path = write_grammar(tmp_dir, Support.ExampleGrammars.all()["4.1 calculator"])
    out_path = Path.join(tmp_dir, "gen_calc.ex")
    module = unique_module("GenPeg")

    output =
      capture_io(fn ->
        Mix.Tasks.Ichor.Gen.run([
          grammar_path,
          "--module",
          inspect(module),
          "--actions",
          "Calculator.Actions",
          "--out",
          out_path
        ])
      end)

    assert output =~ "* creating #{out_path}"

    source = File.read!(out_path)
    refute source =~ ~r/\bdefp\b/
    assert source =~ "# Do not edit by hand"

    [{^module, _}] = Code.compile_file(out_path)
    assert module.run("2 + 3 * 4") == {:ok, 14}
  end

  test "writes a compilable module for an lr grammar", %{tmp_dir: tmp_dir} do
    out_path = Path.join(tmp_dir, "gen_lr.ex")
    module = unique_module("GenLr")

    capture_io(fn ->
      Mix.Tasks.Ichor.Gen.run([
        "test/lr_calculator/lr_calculator.aether",
        "--module",
        inspect(module),
        "--actions",
        "LrCalculator.Actions",
        "--out",
        out_path
      ])
    end)

    [{^module, _}] = Code.compile_file(out_path)
    assert module.run("2+3*4") == {:ok, 14}
  end

  test "creates intermediate directories for --out", %{tmp_dir: tmp_dir} do
    grammar_path = write_grammar(tmp_dir, Support.ExampleGrammars.all()["4.1 calculator"])
    out_path = Path.join([tmp_dir, "nested", "dir", "gen.ex"])

    capture_io(fn ->
      Mix.Tasks.Ichor.Gen.run([
        grammar_path,
        "--module",
        inspect(unique_module("GenNested")),
        "--actions",
        "Calculator.Actions",
        "--out",
        out_path
      ])
    end)

    assert File.exists?(out_path)
  end

  test "raises with a formatted Ichor.Error on a grammar that fails to parse", %{tmp_dir: tmp_dir} do
    grammar_path = write_grammar(tmp_dir, "not a valid grammar at all")
    out_path = Path.join(tmp_dir, "gen.ex")

    assert_raise Mix.Error, ~r/expected @grammar/, fn ->
      capture_io(fn ->
        Mix.Tasks.Ichor.Gen.run([
          grammar_path,
          "--module",
          "Whatever",
          "--actions",
          "Whatever.Actions",
          "--out",
          out_path
        ])
      end)
    end
  end

  test "raises usage error when --module is missing" do
    assert_raise Mix.Error, ~r/missing required --module.*usage: mix ichor\.gen/s, fn ->
      Mix.Tasks.Ichor.Gen.run(["grammar.aether", "--actions", "A", "--out", "out.ex"])
    end
  end

  test "raises usage error when --actions is missing" do
    assert_raise Mix.Error, ~r/missing required --actions/, fn ->
      Mix.Tasks.Ichor.Gen.run(["grammar.aether", "--module", "A", "--out", "out.ex"])
    end
  end

  test "raises usage error when --out is missing" do
    assert_raise Mix.Error, ~r/missing required --out/, fn ->
      Mix.Tasks.Ichor.Gen.run(["grammar.aether", "--module", "A", "--actions", "A.Actions"])
    end
  end

  test "raises usage error when not given exactly one path" do
    assert_raise Mix.Error, ~r/usage/i, fn ->
      Mix.Tasks.Ichor.Gen.run(["--module", "A", "--actions", "A.Actions", "--out", "out.ex"])
    end
  end

  defp write_grammar(tmp_dir, source) do
    path = Path.join(tmp_dir, "grammar_#{System.unique_integer([:positive])}.aether")
    File.write!(path, source)
    path
  end

  defp unique_module(prefix) do
    Module.concat([:"#{prefix}#{System.unique_integer([:positive])}"])
  end
end
