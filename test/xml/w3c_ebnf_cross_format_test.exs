defmodule XML.W3CEBNFCrossFormatTest do
  @moduledoc """
  `Ichor.EBNF.W3C` had no real-world-named fixture at all before this --
  every other importer (ABNF, ISO EBNF, PEG) has one via
  `test/http/`/`test/lisp/`/`test/logql/`/`test/regex/`/`test/sql/`'s
  own cross-format tests, but ISO EBNF was the only *EBNF* dialect with
  one, even though W3C EBNF is the more consequential real-world
  notation of the two -- it's literally the notation the W3C invented
  *for*, and uses throughout, the XML and XML Schema specs themselves
  (`https://www.w3.org/TR/xml/#sec-notation`).

  `test/xml/xml.ebnf-w3c` is a deliberately small subset of the real
  XML 1.0 grammar, keeping the spec's own production *names*
  (`STag`/`ETag`/`EmptyElemTag`/`NameStartChar`/... -- so this reads
  like recognizably-real XML grammar, not a renamed stand-in), while
  cutting scope in ways worth calling out clearly: no DOCTYPE/prolog, no
  comments/CDATA/processing instructions/entity references, no
  namespaces, character classes narrowed from the spec's full Unicode
  ranges to plain ASCII (matching how every other fixture in this suite
  already narrows Unicode-scale specs to ASCII subsets), and -- the
  fixture's own most interesting finding, documented in the grammar
  file itself right above `CharData`'s definition -- text *content*
  restricted to digits/punctuation, no letters, because Ichor's
  tokenizer picks one tokenization per position by global maximal
  munch with no notion of "inside a tag" vs "in content" the way real
  XML's own genuinely context-sensitive lexer has; letter-only content
  like "hello" would otherwise tokenize identically to a `Name` token.
  Attribute *values* aren't affected (unambiguously quote-delimited), so
  they can and do contain ordinary letters. The spec's own leading `[N]`
  production numbers are dropped too -- `Ichor.EBNF.W3C`'s own grammar
  (`priv/grammar/ebnf-w3c.aether`) has no syntax for them at all, a
  real, if minor, limitation of the importer itself, not this fixture.
  """

  use ExUnit.Case, async: true

  alias Support.CrossFormat

  @valid [
    "<br/>",
    "<p>1</p>",
    "<p>1<em>2</em>!</p>",
    ~s(<a href="https://example.com">1</a>),
    "<div><p>1</p><p>2</p></div>",
    ~s(<img src="pic.png" alt=""/>)
  ]

  @invalid [
    "<p>1",
    "not xml at all"
  ]

  @tokens [
    :NameStartChar,
    :NameChar,
    :Name,
    :Eq,
    :AttValue,
    :CharData,
    :S
  ]

  defp grammar do
    {:ok, ruleset} = "test/xml/xml.ebnf-w3c" |> File.read!() |> Ichor.EBNF.W3C.run()
    ruleset |> CrossFormat.assemble(:document, @tokens) |> CrossFormat.analyze!()
  end

  test "recognizes a small, real subset of XML 1.0 element/attribute/content syntax" do
    grammar = grammar()

    for input <- @valid do
      assert CrossFormat.accepts?(grammar, input), "expected #{inspect(input)} to be accepted"
    end
  end

  test "rejects malformed or non-XML input" do
    grammar = grammar()

    for input <- @invalid do
      refute CrossFormat.accepts?(grammar, input), "expected #{inspect(input)} to be rejected"
    end
  end

  test "nested elements of the same name close correctly" do
    assert CrossFormat.accepts?(grammar(), "<p><p>1</p></p>")
  end

  test "a real, well-known XML grammar limitation, reproduced faithfully: mismatched tag names aren't rejected by the context-free grammar alone" do
    # Exactly like the real XML 1.0 spec's own `[39] element` production:
    # matching an ETag's name against its STag's is a well-formedness
    # constraint the spec checks separately in prose, not something any
    # EBNF/CFG production can express -- so `Grammar.VM`, working from
    # this grammar alone, structurally accepts this even though no real
    # XML parser would.
    assert CrossFormat.accepts?(grammar(), "<p><div>1</p></div>")
  end
end
