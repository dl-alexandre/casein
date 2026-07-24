defmodule Casein.UAT.TierB.SocketTransport do
  @moduledoc """
  Default `Casein.UAT.TierB.Transport` — POSTs a JSON-RPC request to the live
  release node over its Unix domain socket (`/run/devide/current.sock`, the canary
  units, NOT the `:4000` dev server — the two-instance split).

  > **Not exercised by the unit suite.** It dials a real release socket, so Tier B
  > envelope/identity/policy logic is tested against a fake transport and this
  > module is verified by the live post-deploy smoke step (open in the plan).

  Uses `:httpc` with a unix-socket `ipfamily`/`unix_socket` option. `endpoint` is
  the socket path; the MCP route is `/api/preview/mcp`.
  """

  @behaviour Casein.UAT.TierB.Transport

  @mcp_path "/api/preview/mcp"

  @impl true
  def rpc(socket_path, request, headers) do
    _ = Application.ensure_all_started(:inets)
    body = Jason.encode!(request)
    url = ~c"http://localhost#{@mcp_path}"

    http_headers =
      headers
      |> Map.put("content-type", "application/json")
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    http_opts = [{:unix_socket, String.to_charlist(socket_path)}, {:timeout, 10_000}]

    case :httpc.request(:post, {url, http_headers, ~c"application/json", body}, http_opts, []) do
      {:ok, {{_v, status, _r}, _h, resp}} when status in 200..299 ->
        decode(resp)

      {:ok, {{_v, status, _r}, _h, resp}} ->
        {:error, {:http_status, status, to_string(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(resp) do
    case Jason.decode(to_string(resp)) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, {:bad_json, reason}}
    end
  end
end
