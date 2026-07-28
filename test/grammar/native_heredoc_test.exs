defmodule Grammar.Native.HeredocTest do
  use ExUnit.Case, async: true

  defp vm_grammar do
    source = File.read!(Path.join(__DIR__, "../heredoc/heredoc.aether"))
    {:ok, grammar} = Aether.Parser.parse(source)
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: vm_grammar()}
  end

  describe "a heredoc's dynamic terminator, both backends" do
    # `:HEREDOC` is captured both bare (the first one) and inside `*`
    # (every repeat), so `Grammar.Analysis`/`Ichor.Actions` normalize
    # every occurrence to a list -- even a single match -- the same
    # "consistent shape regardless of how many times it matched" rule
    # any other repeated capture already follows.
    test "a single heredoc's body comes through as plain text, not the <<EOF/terminator delimiters",
         %{grammar: g} do
      source = "<<EOF\nhello\nworld\nEOF"

      assert {:ok, %Ichor.Node{captures: %{HEREDOC: ["hello\nworld"]}}} =
               Native.Heredoc.run(source)

      assert {:ok, %Ichor.Node{captures: %{HEREDOC: ["hello\nworld"]}}} =
               Grammar.VM.run(g, source, Support.NoActions)
    end

    test "an empty heredoc body", %{grammar: g} do
      source = "<<EOF\nEOF"
      assert {:ok, %Ichor.Node{captures: %{HEREDOC: [""]}}} = Native.Heredoc.run(source)

      assert {:ok, %Ichor.Node{captures: %{HEREDOC: [""]}}} =
               Grammar.VM.run(g, source, Support.NoActions)
    end

    # The whole point: a line that would otherwise look like ordinary
    # "code" (here, another heredoc marker) is just body text, because
    # the *terminator actually declared for this heredoc* is what ends
    # it, not any lexical pattern fixed ahead of time.
    test "a line that looks like a different heredoc marker is just body text", %{grammar: g} do
      source = "<<EOF\n<<OTHER\nEOF"

      assert {:ok, %Ichor.Node{captures: %{HEREDOC: ["<<OTHER"]}}} =
               Native.Heredoc.run(source)

      assert {:ok, %Ichor.Node{captures: %{HEREDOC: ["<<OTHER"]}}} =
               Grammar.VM.run(g, source, Support.NoActions)
    end

    test "two heredocs with different terminators, back to back", %{grammar: g} do
      source = "<<A\nfirst\nA\n<<B\nsecond\nB"

      assert {:ok, %Ichor.Node{captures: %{HEREDOC: ["first", "second"]}}} =
               Native.Heredoc.run(source)

      assert {:ok, %Ichor.Node{captures: %{HEREDOC: ["first", "second"]}}} =
               Grammar.VM.run(g, source, Support.NoActions)
    end

    test "an unterminated heredoc fails to parse", %{grammar: g} do
      source = "<<EOF\nnever ends"
      assert {:error, _} = Native.Heredoc.run(source)
      assert {:error, _} = Grammar.VM.run(g, source, Support.NoActions)
    end
  end
end
