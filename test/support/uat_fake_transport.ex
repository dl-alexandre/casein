defmodule Casein.UAT.FakeTransport do
  @moduledoc """
  In-memory `Casein.UAT.TierB.Transport` for tests. Records the last call
  (endpoint/request/headers) and returns a configurable response, so Tier B
  envelope/identity/policy logic is verifiable without a live release node.
  """

  @behaviour Casein.UAT.TierB.Transport

  def last, do: Process.get({__MODULE__, :last})
  def set_response(resp), do: Process.put({__MODULE__, :resp}, resp)

  @impl true
  def rpc(endpoint, request, headers) do
    Process.put({__MODULE__, :last}, %{endpoint: endpoint, request: request, headers: headers})
    Process.get({__MODULE__, :resp}, {:ok, %{"result" => %{}}})
  end
end
