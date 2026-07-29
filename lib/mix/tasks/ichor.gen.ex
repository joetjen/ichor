defmodule Mix.Tasks.Ichor.Gen do
  @shortdoc "Compiles a grammar file to a plain .ex file, ahead of time"

  @moduledoc """
  Runs the exact same parse -> analyze -> native-codegen pipeline as
  `use Ichor, grammar: ..., actions: ...` (`Ichor.generate/3`), but once,
  from the command line, writing the result to disk as an ordinary
  module instead of splicing it into a macro expansion.

      $ mix ichor.gen calculator.aether \\
          --module Calculator \\
          --actions Calculator.Actions \\
          --out lib/calculator.ex

  The point is moving the expensive part -- parsing the grammar, running
  `Grammar.Analysis`, building an LR/GLR table if `@engine` calls for
  one, and generating Elixir functions from it -- out of the consuming
  app's own `mix compile` (where `use Ichor` would otherwise redo all of
  that on every compile) and into a one-time step whose output gets
  checked in like any other source file.

  The generated module still calls a handful of small support modules by
  name (`Ichor.Actions`, `Ichor.Error`, `Grammar.Native.Runtime.Parser`,
  `Grammar.Native.Runtime.Tokenizer`, `Grammar.VM.Token`, and -- for an
  `@engine lr`/`glr` grammar -- the LR/GLR shift-reduce and GSS runtime)
  for capture dispatch, error formatting, and token matching, exactly as
  `use Ichor`-generated code does. That handful of modules is exactly
  what `ichor_runtime` (`packages/ichor_runtime` in this repo) is: a
  consuming app can depend on `ichor_runtime` as an ordinary runtime
  dependency and mark `ichor` itself `only: :dev, runtime: false` --
  the Aether front-end, the format importers, `Grammar.Analysis`, the
  LR/GLR table builder, and the codegen backends themselves (the bulk of
  the library) genuinely never ship, including in a `mix release` build.

  Every private helper function the codegen backend generates
  (tokenizer/rule sub-functions, LR/GLR dispatch clauses, ...) is
  emitted as `def`, not `defp`: through `use Ichor`, these come from
  macro expansion, which Elixir's compiler doesn't flag for being
  unused even when a particular grammar's shape leaves some unreferenced
  (e.g. a predefined token like `HEX` no rule actually uses); written
  out as ordinary source, the same functions would trip
  `--warnings-as-errors` on an unrelated grammar-shape detail.

  Regenerate by rerunning the same command whenever the grammar changes
  -- there's no automatic staleness check between the checked-in file
  and its source grammar.

  ## Options

    * `--module` (required) -- the generated module's name, e.g.
      `MyApp.Calculator`.
    * `--actions` (required) -- the `Ichor.Actions` module the generated
      `run/1,2` dispatches to, e.g. `MyApp.Calculator.Actions`. Not
      required to exist yet -- it's baked in as a literal module
      reference, resolved when the generated file's own callers run, not
      when it's generated.
    * `--out` (required) -- path to write the generated module to.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {switches, args} =
      OptionParser.parse!(argv, strict: [module: :string, actions: :string, out: :string])

    case args do
      [path] -> generate(path, switches)
      _ -> usage()
    end
  end

  defp generate(path, switches) do
    with {:ok, module} <- fetch_switch(switches, :module),
         {:ok, actions} <- fetch_switch(switches, :actions),
         {:ok, out} <- fetch_switch(switches, :out) do
      write(path, Module.concat([module]), Module.concat([actions]), out)
    else
      {:error, message} -> usage(message)
    end
  end

  defp fetch_switch(switches, key) do
    case Keyword.fetch(switches, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "missing required --#{key}"}
    end
  end

  defp write(path, module, actions_module, out) do
    source = File.read!(path)
    body = Ichor.generate(source, path, actions_module)

    text =
      quote do
        defmodule unquote(module) do
          @moduledoc false
          unquote(publicize(body))
        end
      end
      |> Macro.to_string()
      |> Code.format_string!()
      |> IO.iodata_to_binary()

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, banner(path, module, actions_module, out) <> text <> "\n")
    Mix.shell().info("* creating #{out}")
  rescue
    e in CompileError -> Mix.raise(e.description)
  end

  # `use Ichor`-generated helpers are `defp` because they're spliced by
  # a macro into the caller's own module, where Elixir's unused-function
  # check doesn't flag macro-originated code; written out as plain
  # source, the same `defp`s would need every grammar-specific helper to
  # actually be reachable from this one grammar's shape, which isn't
  # true in general (a predefined token like `HEX` compiles a lexer
  # function whether or not any rule in *this* grammar uses it). `def`
  # sidesteps that without having to reason about which helpers happen
  # to be reachable.
  defp publicize(body) do
    Macro.postwalk(body, fn
      {:defp, meta, args} -> {:def, meta, args}
      other -> other
    end)
  end

  defp banner(path, module, actions_module, out) do
    """
    # Generated by:
    #
    #     mix ichor.gen #{path} --module #{inspect(module)} --actions #{inspect(actions_module)} --out #{out}
    #
    # Do not edit by hand -- rerun the command above instead.
    """
  end

  @spec usage() :: no_return()
  defp usage, do: usage(nil)

  @spec usage(String.t() | nil) :: no_return()
  defp usage(message) do
    usage_line =
      "usage: mix ichor.gen PATH_TO_GRAMMAR --module MODULE --actions ACTIONS_MODULE --out PATH"

    Mix.raise(if message, do: "#{message}\n#{usage_line}", else: usage_line)
  end
end
