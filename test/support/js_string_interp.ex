defmodule JS.StringInterp do
  @moduledoc """
  Toy stand-in for a JS-style template literal (`"a#{1 + 2}b"`): scanning a
  string literal needs to switch, mid-token, from raw character scanning
  to full rule-level parsing (the embedded `expr`) and back -- exactly
  the "a token needs to recurse into a rule" problem no fixed
  maximal-munch tokenizer can express, and the reason
  `Ichor.CustomLexeme`'s `rule_matchers` exists at all.

  Returns an explicit `{:rule, :string, %{segments: [...]}}` capture
  override -- an interleaved list of literal-text segments
  (`{:text, chunk}`) and embedded-expression segments (whatever
  `rule_matchers.expr` itself produced) -- so the embedded expression's
  parsed structure reaches `Ichor.Actions` intact instead of collapsing
  into flat text.
  """

  def scan(input, _context, %{expr: expr}) do
    with <<"\"", rest::binary>> <- input,
         {:ok, segments, rest2} <- scan_body(rest, expr, [], "") do
      text = binary_part(input, 0, byte_size(input) - byte_size(rest2))
      {:ok, text, rest2, {:rule, :string, %{segments: segments}}}
    else
      _ -> :fail
    end
  end

  defp scan_body(<<"\"", rest::binary>>, _expr, segs, acc) do
    {:ok, Enum.reverse(flush(acc, segs)), rest}
  end

  defp scan_body(<<"\#{", rest::binary>>, expr, segs, acc) do
    case expr.(rest) do
      {:ok, _text, <<"}", rest2::binary>>, capture} ->
        scan_body(rest2, expr, [capture | flush(acc, segs)], "")

      _ ->
        :fail
    end
  end

  defp scan_body(<<c::utf8, rest::binary>>, expr, segs, acc) do
    scan_body(rest, expr, segs, acc <> <<c::utf8>>)
  end

  defp scan_body(<<>>, _expr, _segs, _acc), do: :fail

  defp flush("", segs), do: segs
  defp flush(acc, segs), do: [{:text, acc} | segs]
end
