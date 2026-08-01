defmodule CaseinWeb.API.McpTicketControllerTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.Agents.AgentCapabilityTokens
  alias Casein.Audit

  @workspace_id "mcp-ticket-ws"

  setup do
    previous_base = Application.get_env(:casein, :agent_mcp_base_url)
    previous_limit = Application.fetch_env!(:casein, CaseinWeb.Plugs.McpTicketRateLimit)
    Application.put_env(:casein, :agent_mcp_base_url, "http://127.0.0.1:4000")
    Audit.clear()

    on_exit(fn ->
      restore(:agent_mcp_base_url, previous_base)
      Application.put_env(:casein, CaseinWeb.Plugs.McpTicketRateLimit, previous_limit)
    end)

    {:ok, capability, _record} = AgentCapabilityTokens.create_for_grok(capability_attrs())
    %{capability: capability}
  end

  test "authenticated capability exchanges only a scope subset", %{conn: conn, capability: token} do
    response =
      conn
      |> exchange(token, %{
        workspace_id: @workspace_id,
        surface: "terminal",
        scopes: ["terminal_capture"]
      })
      |> json_response(201)

    assert response["ticket"] =~ "mcptkt_"
    assert response["workspace_id"] == @workspace_id
    assert response["surface"] == "terminal"
    assert response["scopes"] == ["terminal_capture"]
    assert response["expires_in"] == 300
    assert response["url"] =~ "/api/terminals/mcp?"
    assert response["url"] =~ "ticket=" <> response["ticket"]
    assert response["url"] =~ "workspace_id=#{@workspace_id}"

    assert Enum.any?(Audit.list(), fn event ->
             event.action == "agent.mcp_ticket.exchanged" and
               event.workspace_id == @workspace_id and
               event.target_ref == response["ticket_id"] and
               event.actor_id =~ "agent_capability:"
           end)

    refute inspect(Audit.list()) =~ response["ticket"]
  end

  test "ticket cannot carry scopes the presenting credential lacked", %{
    conn: conn,
    capability: token
  } do
    response =
      conn
      |> exchange(token, %{
        workspace_id: @workspace_id,
        surface: "terminal",
        scopes: ["terminal_send_command"]
      })
      |> json_response(403)

    assert response["error"] == "ticket_scope_escalation"
  end

  test "cross-workspace and non-capability callers are rejected", %{conn: conn, capability: token} do
    mismatched =
      conn
      |> exchange(token, %{
        workspace_id: "other-workspace",
        surface: "terminal",
        scopes: ["terminal_capture"]
      })

    assert json_response(mismatched, 403)["error"] == "ticket_workspace_mismatch"

    unauthenticated =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> post("/api/mcp-tickets/exchange", %{})

    assert unauthenticated.status in [401, 503]
  end

  test "exchange is rate limited per authenticated capability", %{
    conn: conn,
    capability: token
  } do
    Application.put_env(:casein, CaseinWeb.Plugs.McpTicketRateLimit,
      scale_ms: 60_000,
      limit: 1
    )

    params = %{
      workspace_id: @workspace_id,
      surface: "terminal",
      scopes: ["terminal_capture"]
    }

    assert exchange(conn, token, params).status == 201

    limited = exchange(build_conn(), token, params)
    assert json_response(limited, 429) == %{"error" => "rate_limited"}
    assert get_resp_header(limited, "retry-after") != []
  end

  defp exchange(conn, token, params) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/api/mcp-tickets/exchange", params)
  end

  defp capability_attrs do
    %{
      workspace_id: @workspace_id,
      runtime: "grok",
      tmux_session_id: "casein_mcp-ticket-ws_agent",
      pane_id: "%7",
      leader_id: String.duplicate("a", 24),
      bundle_digest: String.duplicate("b", 64),
      workspace_mode: "manual",
      allowed_tools: %{
        "terminal" => ["terminal_capture", "terminal_list_sessions"],
        "preview" => ["preview_screenshot"]
      },
      checkout_digest: String.duplicate("c", 64)
    }
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
