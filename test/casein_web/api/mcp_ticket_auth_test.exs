defmodule CaseinWeb.API.McpTicketAuthTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.Agents.{AgentCapabilityTokens, McpTickets, MCPUrls}

  @workspace_id "mcp-ticket-auth-ws"
  @now ~U[2026-08-01 10:00:00.000000Z]

  setup do
    previous_clock = Application.fetch_env!(:casein, :mcp_ticket_clock)
    Application.put_env(:casein, :mcp_ticket_clock, fn -> @now end)

    insert(:workspace_record,
      external_id: @workspace_id,
      name: @workspace_id,
      mode: "manual"
    )

    {:ok, bearer, _record} = AgentCapabilityTokens.create_for_grok(capability_attrs())
    {:ok, claims} = AgentCapabilityTokens.verify(bearer)

    on_exit(fn -> Application.put_env(:casein, :mcp_ticket_clock, previous_clock) end)

    %{bearer: bearer, claims: claims}
  end

  test "ticket authorizes one MCP request and replay is rejected", %{claims: claims} do
    {:ok, issued} = McpTickets.issue(claims, "terminal", ["terminal_list_sessions"])
    url = ticket_url(issued.ticket)

    first = mcp_post(url)
    assert json_response(first, 200)["result"]["tools"]
    assert first.assigns.api_token_scope == {:mcp_ticket, issued.id}

    replay = mcp_post(url)
    assert json_response(replay, 401)["error"] == "invalid_mcp_ticket"
  end

  test "expired ticket is rejected without sleeping", %{claims: claims} do
    {:ok, issued} = McpTickets.issue(claims, "terminal", ["terminal_list_sessions"])
    Application.put_env(:casein, :mcp_ticket_clock, fn -> DateTime.add(@now, 301, :second) end)

    assert mcp_post(ticket_url(issued.ticket)).status == 401
  end

  test "ticket for workspace A cannot be used against workspace B", %{claims: claims} do
    {:ok, issued} = McpTickets.issue(claims, "terminal", ["terminal_list_sessions"])

    wrong_url =
      MCPUrls.ticket_url(
        "terminal",
        "workspace-b",
        claims.tmux_session_id,
        issued.ticket
      )

    assert json_response(mcp_post(wrong_url), 401)["error"] == "invalid_mcp_ticket"
    assert mcp_post(ticket_url(issued.ticket)).status == 200
  end

  test "existing capability bearer auth still works unchanged", %{bearer: bearer, claims: claims} do
    url =
      MCPUrls.terminal_url(@workspace_id,
        tmux_session: claims.tmux_session_id
      )

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> bearer)
      |> mcp_post(url)

    assert json_response(conn, 200)["result"]["tools"]
    assert match?({:agent_capability, _id}, conn.assigns.api_token_scope)
  end

  defp ticket_url(ticket) do
    MCPUrls.ticket_url(
      "terminal",
      @workspace_id,
      capability_attrs().tmux_session_id,
      ticket
    )
  end

  defp mcp_post(conn \\ build_conn(), url) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> post(url, %{jsonrpc: "2.0", id: 1, method: "tools/list"})
  end

  defp capability_attrs do
    %{
      workspace_id: @workspace_id,
      runtime: "grok",
      tmux_session_id: "casein_mcp-ticket-auth-ws_agent",
      pane_id: "%7",
      leader_id: String.duplicate("d", 24),
      bundle_digest: String.duplicate("e", 64),
      workspace_mode: "manual",
      allowed_tools: %{"terminal" => ["terminal_list_sessions"]},
      checkout_digest: String.duplicate("f", 64)
    }
  end
end
