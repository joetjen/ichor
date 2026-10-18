defmodule Mix.Tasks.Ichor.Conformance do
  @shortdoc "Answers an Ichor Runtime Conformance Suite request"

  @moduledoc """
      $ mix ichor.conformance interpreted|compiled REQUEST ANSWER

  This implementation's adapter for the Ichor Runtime Conformance
  Suite: reads the JSON request at `REQUEST`, answers every case through
  the named backend (`Ichor.Conformance`), and writes the JSON answer to
  `ANSWER`.

  Exits non-zero only when the adapter itself cannot work -- no request
  file, a request that is not JSON, a backend it does not have -- never
  because a case failed: a failed case is an answer, and the suite
  judges it.
  """

  use Mix.Task

  @usage "usage: mix ichor.conformance interpreted|compiled REQUEST ANSWER"

  # Spelled out rather than made with `String.to_existing_atom/1`: from
  # the command line nothing has loaded `Ichor.Conformance` yet, so its
  # atoms do not exist at the moment the argument is read.
  @backends %{"interpreted" => :interpreted, "compiled" => :compiled}

  @impl Mix.Task
  def run(argv) do
    case argv do
      [backend, request, answer] when is_map_key(@backends, backend) ->
        respond(Map.fetch!(@backends, backend), request, answer)

      _ ->
        Mix.raise(@usage)
    end
  end

  defp respond(backend, request, answer) do
    response =
      request
      |> File.read!()
      |> JSON.decode!()
      |> Ichor.Conformance.answer(backend)

    File.write!(answer, JSON.encode!(response))
  end
end
