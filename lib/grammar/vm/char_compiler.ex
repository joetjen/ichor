defmodule Grammar.VM.CharCompiler do
  @moduledoc """
  Compiles every token in a grammar (character-level: `Literal`,
  `CharClass`, `Any`, and `RuleRef` to another token -- the only node
  shapes a token body can contain) into one linked `Grammar.VM.Program`,
  run by `Grammar.VM.Lexer`.
  """

  alias Grammar.IR
  alias Grammar.VM.{Compiler, Linker}

  @spec compile(%{atom() => IR.expr()}) :: Grammar.VM.Program.t()
  def compile(tokens) do
    {named_ops, _counter} =
      Enum.reduce(tokens, {[], 0}, fn {name, ir}, {acc, counter} ->
        {ops, counter} = Compiler.compile(ir, counter, &leaf/2)
        {[{name, ops ++ [{:return}]} | acc], counter}
      end)

    Linker.link(Enum.reverse(named_ops))
  end

  defp leaf(%IR.Literal{value: v}, counter), do: {[{:lit, v}], counter}
  defp leaf(%IR.CharClass{ranges: r}, counter), do: {[{:set, r}], counter}
  defp leaf(%IR.Any{}, counter), do: {[{:any}], counter}
  defp leaf(%IR.RuleRef{name: name}, counter), do: {[{:call, name}], counter}
end
