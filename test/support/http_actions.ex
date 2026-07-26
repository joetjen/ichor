defmodule HTTP.Actions do
  @moduledoc """
  "The grammar alone isn't enough" for a real HTTP body -- `body`'s
  grammar-level match is necessarily every remaining byte (there's no
  way for the grammar itself to know how many bytes belong to the
  body), so this module's own job is to read `Content-Length` back out
  of the already-parsed headers and truncate the grammar's greedy body
  match down to the declared length.

  Getting the grammar to parse at all first required fixing three
  maximal-munch conflicts baked into the grammar text itself (not just
  an Actions-layer concern):

    - `HEADER_VALUE := (!"\\r" !"\\n" .)+` has no other exclusions, so it
      can match all the way to the first CRLF from *any* position --
      including the very start of the request line, where it
      out-lengths `METHOD` outright and swallows the whole line. Real
      HTTP header values and the request line's URI/version genuinely
      need the same "run of non-delimiter characters" token; merging
      them into one `WORD` token (matching this fixture's `class_atom`
      fix for the regex grammar) removes the separate,
      even-greedier `HEADER_VALUE`/`HEADER_NAME`/`URI` names entirely.
    - `@skip HWS` auto-splices a `HWS` skip-star into every gap, but
      `request_line`'s own `SP` token (needed so the grammar can reject
      `GET  /path` -- two spaces) ties
      with `HWS` for an ordinary single space, and declaration order can
      only ever resolve that one way, breaking whichever side loses.
      Switching the whole grammar to `@noskip` and writing every gap
      explicitly (`SP` once in `request_line`, `SP*`/`SP+` where
      multiple spaces should be tolerated in `header`) sidesteps the
      conflict rather than picking a side.
    - `BODY_BYTE := .` (any single byte) always loses the same
      maximal-munch race to `WORD` for ordinary body text, for the same
      reason `HEADER_VALUE` did -- `WORD` can always match more
      characters per token than a lone `BODY_BYTE` can. `body` now
      reuses the same `WORD`/`SP`/`COLON`/`CRLF` tokens already declared
      for the rest of the grammar, captured as one `:text` span
      (`content:((WORD | SP | COLON | CRLF)*)`) rather than needing its
      own byte-level token at all.
  """

  @behaviour Ichor.Actions

  @impl true
  def handle_token(:METHOD, text, _ctx), do: {:ok, text}
  def handle_token(:WORD, text, _ctx), do: {:ok, text}
  def handle_token(:HTTP_VERSION, text, _ctx), do: {:ok, text}

  @impl true
  def handle_rule(:header, %{name: name_cap, value: value_cap}, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx),
         {:ok, value, ctx} <- value_cap.eval.(ctx) do
      {:ok, {name, value}, ctx}
    end
  end

  def handle_rule(
        :request_line,
        %{METHOD: method_cap, uri: uri_cap, HTTP_VERSION: version_cap},
        ctx
      ) do
    with {:ok, method, ctx} <- method_cap.eval.(ctx),
         {:ok, uri, ctx} <- uri_cap.eval.(ctx),
         {:ok, version, ctx} <- version_cap.eval.(ctx) do
      {:ok, %{method: method, uri: uri, version: version}, ctx}
    end
  end

  def handle_rule(:body, %{content: cap}, ctx), do: cap.eval.(ctx)

  def handle_rule(:request, captures, ctx) do
    with {:ok, request_line, ctx} <- captures.request_line.eval.(ctx),
         {:ok, %{header: header_pairs}, ctx} <-
           Ichor.Actions.eval_all(%{header: captures.header}, ctx),
         {:ok, raw_body, ctx} <- eval_body(captures, ctx) do
      headers = Map.new(header_pairs)
      body = truncate_body(headers, raw_body)
      {:ok, Map.merge(request_line, %{headers: headers, body: body}), ctx}
    end
  end

  defp eval_body(%{body: cap}, ctx), do: cap.eval.(ctx)
  defp eval_body(_captures, ctx), do: {:ok, "", ctx}

  defp truncate_body(headers, raw_body) do
    case find_content_length(headers) do
      nil -> raw_body
      length -> binary_part(raw_body, 0, min(length, byte_size(raw_body)))
    end
  end

  defp find_content_length(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == "content-length", do: String.to_integer(value)
    end)
  end
end
