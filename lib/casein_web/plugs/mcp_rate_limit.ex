defmodule CaseinWeb.Plugs.McpRateLimit do
  @moduledoc """
  Per-token rate limiting for agent MCP endpoints.

  Applied after `ApiAuth` so only authenticated traffic is metered. Uses a
  hashed bearer token fingerprint — the raw token is never stored in ETS.
  """

  import Plug.Conn

  alias Casein.RateLimit

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
    [
      "mcp",
      conn.request_path,
      token_fingerprint(conn),
      tool_name(conn),
      workspace_id(conn),
      tmux_session(conn)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp tool_name(%{body_params: %{"method" => "tools/call", "params" => %{"name" => name}}})
       when is_binary(name) and name != "",
       do: "tool=#{name}"

  defp tool_name(_conn), do: nil

  defp workspace_id(conn) do
    case tool_args(conn) do
      args when is_map(args) ->
        value(args, "workspace_id") || query_or_assigned_workspace(conn)

      _ ->
        query_or_assigned_workspace(conn)
    end
    |> scoped_part("workspace")
  end

  defp query_or_assigned_workspace(conn) do
    conn = fetch_query_params(conn)
    conn.query_params["workspace_id"] || conn.assigns[:api_workspace_id]
  end

  defp tmux_session(conn) do
    case tool_args(conn) do
      args when is_map(args) -> value(args, "tmux_session")
      _ -> nil
    end
    |> scoped_part("session")
  end

  defp tool_args(%{body_params: %{"method" => "tools/call", "params" => %{"arguments" => args}}})
       when is_map(args),
       do: args

  defp tool_args(_conn), do: nil

  defp value(map, key) do
    case Map.get(map, key) || Map.get(map, atom_key(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp atom_key("workspace_id"), do: :workspace_id
  defp atom_key("tmux_session"), do: :tmux_session
  defp atom_key(_key), do: nil

  defp scoped_part(nil, _label), do: nil
  defp scoped_part("", _label), do: nil

  defp scoped_part(value, label) when is_binary(value) do
    "#{label}=#{Base.url_encode64(value, padding: false)}"
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
    Application.get_env(:casein, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
