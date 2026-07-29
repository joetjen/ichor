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

  describe "non-Aether styles: extension auto-detection" do
    test "abnf", %{tmp_dir: tmp_dir} do
      run_import_style(tmp_dir, ".abnf", "num = 1*3DIGIT\r\n", "num", "255")
    end

    test "bnf", %{tmp_dir: tmp_dir} do
      run_import_style(
        tmp_dir,
        ".bnf",
        "<num> ::= <digit> <num> | <digit>\n<digit> ::= '0' | '1' | '2'\n",
        "num",
        "12"
      )
    end

    test "ebnf", %{tmp_dir: tmp_dir} do
      run_import_style(
        tmp_dir,
        ".ebnf",
        "num = digit, { digit } ;\ndigit = '0' | '1' | '2' ;\n",
        "num",
        "12"
      )
    end

    test "peg", %{tmp_dir: tmp_dir} do
      run_import_style(tmp_dir, ".peg", "num <- digit+\ndigit <- [0-2]\n", "num", "12")
    end

    test "unrecognized extension falls back to Aether", %{tmp_dir: tmp_dir} do
      path = write_grammar_ext(tmp_dir, ".txt", Support.ExampleGrammars.all()["4.1 calculator"])
      out_path = Path.join(tmp_dir, "gen.ex")
      module = unique_module("GenUnknownExt")

      capture_io(fn ->
        Mix.Tasks.Ichor.Gen.run([
          path,
          "--module",
          inspect(module),
          "--actions",
          "Calculator.Actions",
          "--out",
          out_path
        ])
      end)

      [{^module, _}] = Code.compile_file(out_path)
      assert module.run("2 + 3 * 4") == {:ok, 14}
    end
  end

  describe "@style pragma override" do
    test "overrides the extension, and is stripped before the target parser sees it", %{
      tmp_dir: tmp_dir
    } do
      source = "@style abnf\nnum = 1*3DIGIT\r\n"
      path = write_grammar_ext(tmp_dir, ".peg", source)
      out_path = Path.join(tmp_dir, "gen.ex")
      module = unique_module("GenStylePragma")

      capture_io(fn ->
        Mix.Tasks.Ichor.Gen.run([
          path,
          "--module",
          inspect(module),
          "--actions",
          "Whatever.Actions",
          "--out",
          out_path
        ])
      end)

      [{^module, _}] = Code.compile_file(out_path)
      assert {:ok, 3, _captures} = module.parse("255")
    end

    test "an unknown @style name is a usage error", %{tmp_dir: tmp_dir} do
      path = write_grammar_ext(tmp_dir, ".peg", "@style nonsense\nnum <- [0-9]\n")
      out_path = Path.join(tmp_dir, "gen.ex")

      assert_raise Mix.Error, ~r/unknown @style "nonsense"/, fn ->
        capture_io(fn ->
          Mix.Tasks.Ichor.Gen.run([
            path,
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
  end

  describe "--root" do
    test "overrides the source's own first-declared rule", %{tmp_dir: tmp_dir} do
      source = "num <- digit+\ndigit <- [0-9]\n"
      path = write_grammar_ext(tmp_dir, ".peg", source)
      out_path = Path.join(tmp_dir, "gen.ex")
      module = unique_module("GenRoot")

      capture_io(fn ->
        Mix.Tasks.Ichor.Gen.run([
          path,
          "--module",
          inspect(module),
          "--actions",
          "Whatever.Actions",
          "--out",
          out_path,
          "--root",
          "digit"
        ])
      end)

      [{^module, _}] = Code.compile_file(out_path)
      assert {:ok, 1, _captures} = module.parse("9")
      assert {:error, _} = module.parse("99")
    end
  end

  test "raises with a formatted Ichor.Error when a non-Aether source declares no rules", %{
    tmp_dir: tmp_dir
  } do
    path = write_grammar_ext(tmp_dir, ".abnf", "\r\n")
    out_path = Path.join(tmp_dir, "gen.ex")

    assert_raise Mix.Error, ~r/declares no rules/, fn ->
      capture_io(fn ->
        Mix.Tasks.Ichor.Gen.run([
          path,
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

  defp run_import_style(tmp_dir, ext, source, root_module_name, input) do
    path = write_grammar_ext(tmp_dir, ext, source)
    out_path = Path.join(tmp_dir, "gen#{String.replace(ext, ".", "")}.ex")
    tag = ext |> String.replace(".", "") |> String.upcase()
    module = unique_module("Gen#{String.upcase(root_module_name)}#{tag}")

    capture_io(fn ->
      Mix.Tasks.Ichor.Gen.run([
        path,
        "--module",
        inspect(module),
        "--actions",
        "Whatever.Actions",
        "--out",
        out_path
      ])
    end)

    [{^module, _}] = Code.compile_file(out_path)
    assert {:ok, _len, _captures} = module.parse(input)
  end

  defp write_grammar(tmp_dir, source), do: write_grammar_ext(tmp_dir, ".aether", source)

  defp write_grammar_ext(tmp_dir, ext, source) do
    path = Path.join(tmp_dir, "grammar_#{System.unique_integer([:positive])}#{ext}")
    File.write!(path, source)
    path
  end

  defp unique_module(prefix) do
    Module.concat([:"#{prefix}#{System.unique_integer([:positive])}"])
  end
end
