defmodule HTTP.CrossFormatTest do
  use ExUnit.Case, async: true

  alias Support.CrossFormat

  @valid [
    "GET /index.html HTTP/1.1\r\nHost: example.com\r\n\r\n",
    "GET / HTTP/1.1\r\nHost:    example.com\r\n\r\n",
    "GET / HTTP/1.1\r\nContent-Type: text/html; charset=utf-8\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n",
    "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhelloXXXXX",
    "POST /submit HTTP/1.1\r\nHost: example.com\r\n\r\nhello"
  ]

  @methods ~w(GET POST PUT DELETE HEAD OPTIONS PATCH)

  defp assert_recognizer_parity(grammar) do
    for input <- @valid do
      assert CrossFormat.accepts?(grammar, input), "expected #{inspect(input)} to be accepted"
    end

    for method <- @methods do
      input = "#{method} / HTTP/1.1\r\n\r\n"
      assert CrossFormat.accepts?(grammar, input), "expected #{method} to be a valid method"
    end
  end

  describe "ABNF" do
    test "recognizes the same HTTP request syntax as native Aether's own http grammar" do
      {:ok, ruleset} = "test/http/http.abnf" |> CrossFormat.read_abnf!() |> Ichor.ABNF.run()

      tokens = [:method, :sp, :"digit-char", :"http-version", :crlf, :colon, :word]

      grammar = ruleset |> CrossFormat.assemble(:request, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end

  describe "ISO EBNF" do
    test "recognizes the same HTTP request syntax" do
      {:ok, ruleset} = "test/http/http.ebnf" |> File.read!() |> Ichor.EBNF.ISO.run()

      tokens = [
        :method,
        :sp,
        :"digit char",
        :"http version",
        :crlf,
        :colon,
        :"word char",
        :word
      ]

      grammar = ruleset |> CrossFormat.assemble(:request, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end

  describe "PEG" do
    test "recognizes the same HTTP request syntax" do
      {:ok, ruleset} = "test/http/http.peg" |> File.read!() |> Ichor.PEG.run()

      tokens = [:method, :sp, :digit_char, :http_version, :crlf, :colon, :word_char, :word]

      grammar = ruleset |> CrossFormat.assemble(:request, tokens) |> CrossFormat.analyze!()
      assert_recognizer_parity(grammar)
    end
  end
end
