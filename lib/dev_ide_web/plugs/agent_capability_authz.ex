defmodule CaseinWeb.Plugs.AgentCapabilityAuthz do
  @moduledoc """
  Enforces workspace/session/surface confinement for managed agent bearers.

  Exact tool authorization happens in `MCPEnvelope`, after this plug has
  intersected frozen token grants with the workspace's live policy.
  """

  import Plug.Conn

  alias Casein.Agents.GrokCapabilityPolicy

  @surface_paths %{
    "/api/terminals/mcp" => "terminal",
    "/api/preview/mcp" => "preview",
    "/api/artifacts/mcp" => "artifact"
  }

  def init(opts), do: opts

  def call(%{assigns: %{api_token_scope: {:agent_capability, _id}}} = conn, _opts) do
    conn = fetch_query_params(conn)
    claims = conn.assigns[:api_agent_capability]

    with {:ok, surface} <- surface(conn.request_path),
         :ok <- authorize_workspace(conn, claims),
         :ok <- authorize_tmux_session(conn, surface, claims),
         {:ok, tools, policy} <- GrokCapabilityPolicy.effective_tools(claims) do
      conn
      |> assign(:api_agent_capability_surface, surface)
      |> assign(:api_agent_capability_tools, tools)
      |> assign(:api_agent_capability_policy, policy)
    else
      {:error, reason} -> deny(conn, reason)
    end
  end

  def call(conn, _opts), do: conn

  @doc "Options forwarded by MCP controllers into the shared envelope."
  def handler_opts(conn) do
    case conn.assigns[:api_agent_capability] do
      claims when is_map(claims) ->
        [
          agent_capability: claims,
          agent_capability_surface: conn.assigns[:api_agent_capability_surface],
          agent_capability_tools: conn.assigns[:api_agent_capability_tools] || %{},
          agent_capability_policy: conn.assigns[:api_agent_capability_policy] || %{}
        ]

      _ ->
        []
    end
  end

  defp surface(path) do
    case Map.fetch(@surface_paths, path) do
      {:ok, surface} -> {:ok, surface}
      :error -> {:error, :capability_surface_forbidden}
    end
  end

  defp authorize_workspace(conn, %{workspace_id: expected}) do
    if conn.query_params["workspace_id"] == expected,
      do: :ok,
      else: {:error, :capability_workspace_mismatch}
  end

  defp authorize_workspace(_conn, _claims), do: {:error, :invalid_capability_claims}

  defp authorize_tmux_session(_conn, "artifact", _claims), do: :ok

  defp authorize_tmux_session(conn, _surface, %{tmux_session_id: expected}) do
    if conn.query_params["tmux_session"] == expected,
      do: :ok,
      else: {:error, :capability_session_mismatch}
  end

  defp authorize_tmux_session(_conn, _surface, _claims),
    do: {:error, :invalid_capability_claims}

  defp deny(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      403,
      Jason.encode!(%{
        error: Atom.to_string(reason),
        code: "agent_capability_forbidden",
        message: "Managed agent capability is not valid for this MCP request",
        error_version: "mcp-capability-v1"
      })
    )
    |> halt()
  end
end
