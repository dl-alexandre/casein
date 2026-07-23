defmodule DevIdeWeb.Plugs.DeviceLinkRateLimit do
  @moduledoc """
  Per-client-IP rate limiting for unauthenticated device-link endpoints.

  Device-link exchange cannot use the MCP limiter's bearer-token key because
  the pairing credential is supplied in the request body. This plug reuses the
  shared `DevIDE.RateLimit` service with an IP-scoped bucket per action.

  Expects `DevIdeWeb.Plugs.TrustedProxyRemoteIp` earlier in the pipeline so
  `conn.remote_ip` is the real client behind a loopback reverse proxy (not a
  shared `127.0.0.1` bucket for every peer).
  """

  import Plug.Conn

  alias DevIDE.RateLimit

  @default_scale_ms 60_000
  @default_limit 30

  def init(opts), do: opts

  def call(conn, opts) do
    scale = Keyword.get(opts, :scale_ms, config(:scale_ms, @default_scale_ms))
    limit = Keyword.get(opts, :limit, config(:limit, @default_limit))

    case RateLimit.hit(rate_limit_key(conn), scale, limit) do
      {:allow, _count} ->
        conn

      {:deny, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(max(div(retry_after_ms, 1000), 1)))
        |> put_resp_content_type("application/json")
        |> send_resp(429, ~s({"error":"rate_limited"}))
        |> halt()
    end
  end

  defp rate_limit_key(conn) do
    address = format_address(conn.remote_ip)
    "device_link:#{conn.request_path}:#{address}"
  end

  defp format_address(ip) when is_tuple(ip) and tuple_size(ip) in [4, 8] do
    case :inet.ntoa(ip) do
      address when is_list(address) -> List.to_string(address)
      _ -> "unresolved"
    end
  end

  defp format_address(_ip), do: "unresolved"

  defp config(key, default) do
    Application.get_env(:dev_ide, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
