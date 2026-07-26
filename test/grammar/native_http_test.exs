defmodule Grammar.Native.HTTPTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp vm_grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.6 http"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: vm_grammar()}
  end

  describe "run/1 parity with the VM backend (@noskip, text capture over an alternation)" do
    for source <- [
          "GET /index.html HTTP/1.1\r\nHost: example.com\r\n\r\n",
          "GET / HTTP/1.1\r\nHost:    example.com\r\n\r\n",
          "GET / HTTP/1.1\r\nContent-Type: text/html; charset=utf-8\r\n\r\n",
          "GET / HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n",
          "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhelloXXXXX",
          "POST /submit HTTP/1.1\r\nHost: example.com\r\n\r\nhello",
          "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 100\r\n\r\nhi"
        ] do
      test "#{inspect(source)}", %{grammar: g} do
        source = unquote(source)
        assert Native.HTTP.run(source) == Grammar.VM.run(g, source, HTTP.Actions)
      end
    end

    for method <- ~w(GET POST PUT DELETE HEAD OPTIONS PATCH) do
      test "method #{method}", %{grammar: g} do
        source = "#{unquote(method)} / HTTP/1.1\r\n\r\n"
        assert Native.HTTP.run(source) == Grammar.VM.run(g, source, HTTP.Actions)
      end
    end
  end

  test "request_line's exactly-one-space discipline is rejected on native too" do
    assert {:error, %Ichor.Error{}} = Native.HTTP.run("GET  /index.html HTTP/1.1\r\n\r\n")
    assert {:error, %Ichor.Error{}} = Native.HTTP.run("GET /index.html  HTTP/1.1\r\n\r\n")
  end
end
