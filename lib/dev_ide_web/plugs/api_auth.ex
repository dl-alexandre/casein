defmodule DevIdeWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token gate for the read-only API.

  Token comes from `:dev_ide, :api_token` (preferred for tests) or the
  `DEV_IDE_API_TOKEN` environment variable. If neither is set the API
  refuses every request with 503 — there is no "open by default" mode.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    token = bearer(conn)
    authorize(conn, token, api_tokens())
  end

  defp authorize(conn, token, tokens) do
    case Enum.reject(tokens, fn {_scope, token} -> is_nil(token) end) do
      [] ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, ~s({"error":"api_token_not_configured"}))
        |> halt()

      configured_tokens ->
        case Enum.find(configured_tokens, fn {_scope, expected} ->
               secure_match?(token, expected)
             end) do
          nil ->
            deny(conn)

          {scope, _expected} ->
            authorize_scope(conn, scope)
        end
    end
  end

  defp api_tokens do
    global_tokens =
      [
        Application.get_env(:dev_ide, :api_token),
        System.get_env("DEV_IDE_API_TOKEN")
      ]
      |> Enum.map(&{:global, &1})

    workspace_tokens() ++ global_tokens
  end

  defp workspace_tokens do
    app_tokens = Application.get_env(:dev_ide, :workspace_api_tokens, %{})
    env_tokens = workspace_tokens_from_env(System.get_env("DEV_IDE_WORKSPACE_API_TOKENS"))

    [app_tokens, env_tokens]
    |> Enum.flat_map(&normalize_workspace_tokens/1)
  end

  defp workspace_tokens_from_env(nil), do: %{}
  defp workspace_tokens_from_env(""), do: %{}

  defp workspace_tokens_from_env(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp normalize_workspace_tokens(map) when is_map(map) do
    Enum.flat_map(map, fn
      {token, workspace_id} when is_binary(token) and is_binary(workspace_id) ->
        [{{:workspace, workspace_id}, token}]

      {token, workspace_ids} when is_binary(token) and is_list(workspace_ids) ->
        for workspace_id <- workspace_ids, is_binary(workspace_id) do
          {{:workspace, workspace_id}, token}
        end

      _ ->
        []
    end)
  end

  defp normalize_workspace_tokens(_), do: []

  defp authorize_scope(conn, :global) do
    assign(conn, :api_token_scope, :global)
  end

  defp authorize_scope(conn, {:workspace, workspace_id}) do
    conn = fetch_query_params(conn)

    if workspace_allowed?(conn, workspace_id) do
      conn
      |> assign(:api_token_scope, {:workspace, workspace_id})
      |> assign(:api_workspace_id, workspace_id)
    else
      deny(conn, 403, "workspace_forbidden")
    end
  end

  defp workspace_allowed?(conn, workspace_id) do
    path_workspace_id(conn) == workspace_id or mcp_workspace_allowed?(conn, workspace_id)
  end

  defp path_workspace_id(%{path_info: ["api", "workspaces", workspace_id | _]}), do: workspace_id
  defp path_workspace_id(_), do: nil

  defp mcp_workspace_allowed?(conn, workspace_id) do
    conn.request_path in ["/api/terminals/mcp", "/api/preview/mcp"] and
      conn.query_params["workspace_id"] in [workspace_id, nil, ""]
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp secure_match?(token, expected) when is_binary(token) and is_binary(expected) do
    byte_size(token) == byte_size(expected) and Plug.Crypto.secure_compare(token, expected)
  end

  defp secure_match?(_token, _expected), do: false

  defp deny(conn, status \\ 401, error \\ "unauthorized") do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
