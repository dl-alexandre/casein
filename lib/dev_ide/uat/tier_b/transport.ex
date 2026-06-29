defmodule DevIDE.UAT.TierB.Transport do
  @moduledoc """
  The seam for Tier B's JSON-RPC calls to the **live release node** over its real
  MCP surface (`POST /api/preview/mcp`). `DevIDE.UAT.TierB` owns envelope and
  policy; a Transport owns the wire. The default `SocketTransport` dials the
  release socket; tests inject a fake so envelope/identity/policy logic is
  verifiable without a running node.
  """

  @type request :: map()
  @type headers :: %{optional(String.t()) => String.t()}

  @callback rpc(endpoint :: String.t(), request(), headers()) ::
              {:ok, map()} | {:error, term()}
end
