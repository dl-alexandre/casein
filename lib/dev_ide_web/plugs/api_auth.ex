defmodule CaseinWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token gate for the read-only API.

  Token comes from `:casein, :api_token` (preferred for tests) or the
  `DEV_IDE_API_TOKEN` environment variable. If neither is set the API
  refuses every request with 503 — there is no "open by default" mode.
  """

  import Plug.Conn

  alias Casein.Agents.{AgentCapabilityTokens, OrchestratorTokens}

  def init(opts), do: opts

  def call(conn, _opts) do
    token = bearer(conn)
    authorize(conn, token, api_tokens())
  end

  @doc """
  Audit actor string for the verified token on this conn.

  Derived from the `:api_token_scope` assign this plug sets:
  `"ws:<workspace_id>"` for workspace-scoped tokens,
  `"orchestrator:<subject>"` for self-serve orchestrator tokens, and
  `"global"` for the env global token. Returns nil when the plug has not run
  (callers keep their own fallback).
  """
  @spec actor(Plug.Conn.t()) :: String.t() | nil
  def actor(conn) do
    case conn.assigns[:api_token_scope] do
      {:workspace, workspace_id} when is_binary(workspace_id) -> "ws:" <> workspace_id
      {:orchestrator, subject_id} -> "orchestrator:" <> to_string(subject_id)
      :global -> "global"
      _ -> nil
    end
  end

  defp authorize(conn, token, tokens) do
    configured =
      Enum.reject(tokens, fn {_scope, expected} ->
        is_nil(expected) or reserved_agent_capability?(expected)
      end)

    case Enum.find(configured, fn {_scope, expected} -> secure_match?(token, expected) end) do
      {scope, _expected} ->
        authorize_scope(conn, scope)

      nil ->
        # Fall through to the DB-backed, hash-at-rest orchestrator tokens
        # (self-serve, subject-attributed). Only reached when no env/workspace
        # token matched, so the extra lookup is off the hot path.
        authorize_db_token(conn, token) || fail_closed_or_deny(conn, configured)
    end
  end

  defp authorize_db_token(_conn, nil), do: nil

  defp authorize_db_token(conn, "grokcap_" <> _rest = token) do
    authorize_agent_capability(conn, token)
  end

  defp authorize_db_token(conn, token), do: authorize_orchestrator_token(conn, token)

  defp authorize_agent_capability(conn, token) do
    case AgentCapabilityTokens.verify(token) do
      {:ok, claims} ->
        if agent_capability_path_allowed?(conn.request_path) do
          conn
          |> assign(:api_token_scope, {:agent_capability, claims.id})
          |> assign(:api_workspace_id, claims.workspace_id)
          |> assign(:api_agent_capability, claims)
        else
          deny(conn, 403, "agent_capability_path_forbidden")
        end

      {:error, _reason} ->
        nil
    end
  end

  # An orchestrator token traverses every workspace like the global token but is
  # NOT the env global secret, so `:api_token_scope` is a distinct non-global
  # value and `:api_workspace_id` is left unassigned (per-call confinement stays
  # in the MCP controllers). This keeps it out of the global-token tool-call
  # rejection (CaseinWeb.Endpoint.reject_global_mcp_tool_calls/2).
  defp authorize_orchestrator_token(conn, token) do
    case OrchestratorTokens.verify(token) do
      {:ok, claims} ->
        conn
        |> assign(:api_token_scope, {:orchestrator, claims.subject_id})
        |> assign(:api_token_subject, claims.subject_id)

      {:error, _reason} ->
        nil
    end
  end

  defp agent_capability_path_allowed?(path) do
    path in [
      "/api/terminals/mcp",
      "/api/preview/mcp",
      "/api/artifacts/mcp",
      "/api/agent-capabilities/current"
    ]
  end

  defp fail_closed_or_deny(conn, []) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, ~s({"error":"api_token_not_configured"}))
    |> halt()
  end

  defp fail_closed_or_deny(conn, _configured), do: deny(conn)

  defp api_tokens do
    global_tokens =
      [
        Application.get_env(:casein, :api_token),
        System.get_env("DEV_IDE_API_TOKEN")
      ]
      |> Enum.map(&{:global, &1})

    workspace_tokens() ++ global_tokens
  end

  defp workspace_tokens do
    app_tokens = Application.get_env(:casein, :workspace_api_tokens, %{})
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
    conn.request_path in ["/api/terminals/mcp", "/api/preview/mcp", "/api/artifacts/mcp"] and
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

  defp reserved_agent_capability?("grokcap_" <> _rest), do: true
  defp reserved_agent_capability?(_token), do: false

  defp deny(conn, status \\ 401, error \\ "unauthorized") do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
