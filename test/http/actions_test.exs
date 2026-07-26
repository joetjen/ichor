defmodule HTTP.ActionsTest do
  use ExUnit.Case, async: true

  alias Support.ExampleGrammars

  defp grammar do
    {:ok, grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.6 http"))
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  setup do
    {:ok, grammar: grammar()}
  end

  defp run(grammar, source), do: Grammar.VM.run(grammar, source, HTTP.Actions)

  describe "the http worked example" do
    test "request line and one header, no body", %{grammar: g} do
      assert {:ok,
              %{
                method: "GET",
                uri: "/index.html",
                version: "HTTP/1.1",
                headers: headers,
                body: ""
              }} =
               run(g, "GET /index.html HTTP/1.1\r\nHost: example.com\r\n\r\n")

      assert headers == %{"Host" => "example.com"}
    end
  end

  describe "request_line's exactly-one-space discipline" do
    test "two spaces anywhere in the request line is rejected", %{grammar: g} do
      assert {:error, %Ichor.Error{}} = run(g, "GET  /index.html HTTP/1.1\r\n\r\n")
      assert {:error, %Ichor.Error{}} = run(g, "GET /index.html  HTTP/1.1\r\n\r\n")
    end
  end

  describe "header value tolerance" do
    test "extra spacing after the colon is tolerated, not required", %{grammar: g} do
      assert {:ok, %{headers: %{"Host" => "example.com"}}} =
               run(g, "GET / HTTP/1.1\r\nHost:    example.com\r\n\r\n")
    end

    test "a multi-word header value reconstructs with its original internal spacing", %{
      grammar: g
    } do
      assert {:ok, %{headers: %{"Content-Type" => "text/html; charset=utf-8"}}} =
               run(g, "GET / HTTP/1.1\r\nContent-Type: text/html; charset=utf-8\r\n\r\n")
    end

    test "multiple headers", %{grammar: g} do
      assert {:ok, %{headers: headers}} =
               run(g, "GET / HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n")

      assert headers == %{"Host" => "example.com", "Accept" => "*/*"}
    end
  end

  describe "Content-Length-driven body parsing" do
    test "the body is truncated to exactly Content-Length bytes", %{grammar: g} do
      assert {:ok, %{body: "hello"}} =
               run(
                 g,
                 "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhelloXXXXX"
               )
    end

    test "with no Content-Length header, the whole remaining input is the body", %{grammar: g} do
      assert {:ok, %{body: "hello"}} =
               run(g, "POST /submit HTTP/1.1\r\nHost: example.com\r\n\r\nhello")
    end

    test "Content-Length larger than the actual body doesn't crash", %{grammar: g} do
      assert {:ok, %{body: "hi"}} =
               run(
                 g,
                 "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 100\r\n\r\nhi"
               )
    end
  end

  describe "methods" do
    test "each declared METHOD literal parses", %{grammar: g} do
      for method <- ~w(GET POST PUT DELETE HEAD OPTIONS PATCH) do
        assert {:ok, %{method: ^method}} = run(g, "#{method} / HTTP/1.1\r\n\r\n")
      end
    end
  end
end
