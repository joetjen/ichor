defmodule Markdown.Actions do
  @moduledoc """
  A "markup/transpile"-style `Ichor.Actions` module: eager evaluation,
  bottom-up, each action wrapping its already-transpiled children in
  the corresponding HTML tag.

  Four grammar-level fixes were needed before any of this could run at
  all (the same class of maximal-munch/capture-ordering issues every
  other grammar fixture in this suite hit, not an Actions-layer concern):

    - `SP := " "` ties with `PLAIN_CHAR` (which doesn't exclude space)
      for every ordinary space in running text, and whichever token wins
      the declaration-order tie steals every space from the other's
      domain -- exactly like `HEADER_NAME`/`URI` did for the HTTP
      grammar. Since `heading`/`item` only ever need *some* single
      character between the marker and the inline content, they now
      reference `PLAIN_CHAR` directly instead of a separate `SP`.
    - `URL_CHAR := !")" .` excludes almost nothing, so it ties with (and
      per declaration order, loses to) `PLAIN_CHAR`, `LBRACKET`, and
      everything else a URL could contain. Real markdown link targets
      overwhelmingly consist of characters `PLAIN_CHAR` already accepts
      (no literal `*`/`[`/newline), so `link`'s `url` capture reuses
      `PLAIN_CHAR` too -- a URL containing a literal `*` or `[` is a
      narrow, unexercised gap, the same kind of deliberate cut as the
      regex grammar's bare `-`/`^`.
    - `inline := (bold | link | plain)*` captures each alternative under
      its *own* name (`bold`/`link`/`plain`, each its own list), which
      loses the original interleaving order between them entirely --
      `Ichor`'s capture model groups by name, not by parse position.
      Wrapping the three alternatives in a `segment := bold | link |
      plain` rule and repeating `segment` instead (`inline :=
      segment*`) keeps them in one ordered list, the same "unnamed
      sum-type wrapper" pattern `atom`/`form` already use in the regex
      and LISP grammars.
    - `paragraph := inline (NEWLINE inline)*` -- a genuine grammar bug,
      not a tokenization one: `inline` can legitimately match zero
      segments (an empty bold/link/heading tail is fine), so the blank
      line that's supposed to *end* a paragraph and start the next block
      instead parses as "one more, empty, continuation line" of the
      same paragraph, greedily consuming the very blank line
      `document`'s own `NEWLINE+ block` needs as a separator. A
      lookahead -- `paragraph := inline (NEWLINE !NEWLINE inline)*` --
      rejects a continuation line when the character right after it is
      also a newline, leaving the blank line for `document` to consume.
  """

  @behaviour Ichor.Actions

  @impl true
  def handle_token(:PLAIN_CHAR, text, _ctx), do: {:ok, text}

  @impl true
  def handle_rule(:document, %{block: blocks}, ctx) do
    with {:ok, %{block: htmls}, ctx} <- Ichor.Actions.eval_all(%{block: blocks}, ctx) do
      {:ok, Enum.join(htmls, "\n"), ctx}
    end
  end

  def handle_rule(:plain, %{PLAIN_CHAR: chars}, ctx) do
    with {:ok, %{PLAIN_CHAR: parts}, ctx} <- Ichor.Actions.eval_all(%{PLAIN_CHAR: chars}, ctx) do
      {:ok, Enum.join(parts), ctx}
    end
  end

  def handle_rule(:heading, %{level: hashes, inline: inline_cap}, ctx) do
    with {:ok, level, ctx} <- hashes.eval.(ctx),
         {:ok, html, ctx} <- inline_cap.eval.(ctx) do
      n = String.length(level)
      {:ok, "<h#{n}>#{html}</h#{n}>", ctx}
    end
  end

  def handle_rule(:list, %{item: items}, ctx) do
    with {:ok, %{item: htmls}, ctx} <- Ichor.Actions.eval_all(%{item: items}, ctx) do
      {:ok, "<ul>" <> Enum.map_join(htmls, & &1) <> "</ul>", ctx}
    end
  end

  def handle_rule(:item, %{inline: inline_cap}, ctx) do
    with {:ok, html, ctx} <- inline_cap.eval.(ctx) do
      {:ok, "<li>#{html}</li>", ctx}
    end
  end

  def handle_rule(:paragraph, %{inline: inlines}, ctx) do
    with {:ok, %{inline: htmls}, ctx} <- Ichor.Actions.eval_all(%{inline: inlines}, ctx) do
      {:ok, "<p>" <> Enum.join(htmls, "\n") <> "</p>", ctx}
    end
  end

  def handle_rule(:inline, %{segment: segments}, ctx) do
    with {:ok, %{segment: htmls}, ctx} <- Ichor.Actions.eval_all(%{segment: segments}, ctx) do
      {:ok, Enum.join(htmls), ctx}
    end
  end

  def handle_rule(:bold, %{inline: inline_cap}, ctx) do
    with {:ok, html, ctx} <- inline_cap.eval.(ctx) do
      {:ok, "<strong>#{html}</strong>", ctx}
    end
  end

  def handle_rule(:link, %{inline: inline_cap, url: url_cap}, ctx) do
    with {:ok, html, ctx} <- inline_cap.eval.(ctx),
         {:ok, url, ctx} <- url_cap.eval.(ctx) do
      {:ok, ~s(<a href="#{url}">#{html}</a>), ctx}
    end
  end
end
