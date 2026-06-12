defmodule DevIdeWeb.Plugs.McpRateLimit do
  @moduledoc """
  Per-token rate limiting for agent MCP endpoints.

  Applied after `ApiAuth` so only authenticated traffic is metered. Uses a
  hashed bearer token fingerprint — the raw token is never stored in ETS.
  """

  import Plug.Conn

  alias DevIDE.RateLimit

  @default_scale_ms 60_000
  @default_limit 120

  def init(opts), do: opts

  def call(conn, opts) do
    scale = Keyword.get(opts, :scale_ms, config(:scale_ms, @default_scale_ms))
    limit = Keyword.get(opts, :limit, config(:limit, @default_limit))
    key = rate_limit_key(conn)

    case RateLimit.hit(key, scale, limit) do
      {:allow, _count} ->
        conn

      {:deny, retry_after_ms} ->
        retry_after_s = max(div(retry_after_ms, 1000), 1)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
        |> put_resp_content_type("application/json")
        |> send_resp(429, ~s({"error":"rate_limited"}))
        |> halt()
    end
  end

  defp rate_limit_key(conn) do
    "mcp:#{conn.request_path}:#{token_fingerprint(conn)}"
  end

  defp token_fingerprint(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when is_binary(token) and byte_size(token) > 0 ->
        :crypto.hash(:sha256, token)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)

      _ ->
        "anonymous"
    end
  end

  defp config(key, default) do
    Application.get_env(:dev_ide, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
