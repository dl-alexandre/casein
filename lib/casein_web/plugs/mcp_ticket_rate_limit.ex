defmodule CaseinWeb.Plugs.McpTicketRateLimit do
  @moduledoc """
  Per-capability rate limiting for the authenticated MCP ticket exchange.

  `ApiAuth` runs first, so the bucket uses the verified capability id rather
  than retaining or logging the raw long-lived bearer.
  """

  import Plug.Conn

  alias Casein.RateLimit

  def init(opts), do: opts

  def call(conn, opts) do
    config = Application.fetch_env!(:casein, __MODULE__)
    scale = Keyword.get(opts, :scale_ms, Keyword.fetch!(config, :scale_ms))
    limit = Keyword.get(opts, :limit, Keyword.fetch!(config, :limit))

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
    capability =
      case conn.assigns[:api_token_scope] do
        {:agent_capability, id} -> to_string(id)
        _ -> "non_capability"
      end

    "mcp_ticket_exchange:#{conn.request_path}:#{capability}"
  end
end
