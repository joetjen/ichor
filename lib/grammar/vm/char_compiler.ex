defmodule Grammar.VM.CharCompiler do
  @moduledoc """
  Compiles every token in a grammar (character-level: `Literal`,
  `CharClass`, `Any`, and `RuleRef` to another token -- the only node
  shapes an *ordinary* token body can contain) into one linked
  `Grammar.VM.Program`, run by `Grammar.VM.Tokenizer`.

  A token whose entire body is a `Grammar.IR.CustomLexeme`
  (`@native(...)` at token position) is pulled out separately instead of
  compiled to bytecode -- there's nowhere for a `{:call, name}` from
  another token to jump into for it (see that module's own moduledoc for
  why it can't be composed inside a larger token expression or
  referenced from one), so `Grammar.VM.Tokenizer` dispatches to it directly
  by name via the second map this returns.
  """

  alias Grammar.IR
  alias Grammar.VM.{Compiler, Linker}

  @type custom_lexeme :: {module :: module(), function :: atom(), deps :: [atom()]}

  @spec compile(%{atom() => IR.expr()}) ::
          {Grammar.VM.Program.t(), %{atom() => custom_lexeme()}}
  def compile(tokens) do
    {custom_lexemes, ordinary} = Enum.split_with(tokens, &custom_lexeme?/1)

    custom_lexeme_map =
      Map.new(custom_lexemes, fn {name, %IR.CustomLexeme{module: m, function: f, deps: d}} ->
        {name, {m, f, d}}
      end)

    {named_ops, _counter} =
      Enum.reduce(ordinary, {[], 0}, fn {name, ir}, {acc, counter} ->
        {ops, counter} = Compiler.compile(ir, counter, &leaf/2)
        {[{name, ops ++ [{:return}]} | acc], counter}
      end)

    {Linker.link(Enum.reverse(named_ops)), custom_lexeme_map}
  end

  defp custom_lexeme?({_name, %IR.CustomLexeme{}}), do: true
  defp custom_lexeme?(_), do: false

  defp leaf(%IR.Literal{value: v}, counter), do: {[{:lit, v}], counter}
  defp leaf(%IR.CharClass{ranges: r}, counter), do: {[{:set, r}], counter}
  defp leaf(%IR.Any{}, counter), do: {[{:any}], counter}
  defp leaf(%IR.RuleRef{name: name}, counter), do: {[{:call, name}], counter}
end
