defmodule CaseinWeb.ConnectAgentDrawerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Casein.Agents.OrchestratorToken
  alias CaseinWeb.ConnectAgentDrawer

  test "closed drawer renders nothing" do
    html =
      render_component(&ConnectAgentDrawer.connect_agent_drawer/1,
        open: false,
        tokens: []
      )

    refute html =~ "Connect an external agent"
  end

  test "open drawer shows the mint form and empty-token state" do
    html =
      render_component(&ConnectAgentDrawer.connect_agent_drawer/1,
        open: true,
        tokens: []
      )

    assert html =~ "Connect an external agent"
    assert html =~ ~s(phx-submit="connect:mint")
    assert html =~ "No active tokens."
    # no secret shown before minting
    refute html =~ "shown only once"
  end

  test "a freshly minted token is revealed with copy buttons and the config" do
    html =
      render_component(&ConnectAgentDrawer.connect_agent_drawer/1,
        open: true,
        new_token: "RAW-TOKEN-VALUE",
        mcp_json: ~s({"mcpServers":{}}),
        tokens: []
      )

    assert html =~ "shown only once"
    assert html =~ "RAW-TOKEN-VALUE"
    assert html =~ ~s(phx-hook="CopyText")
    assert html =~ "Copy .mcp.json"
  end

  test "existing tokens render with a scoped revoke button" do
    token = %OrchestratorToken{
      id: "tok-123",
      label: "my laptop",
      last_seen_at: ~U[2026-07-14 12:00:00.000000Z],
      expires_at: ~U[2026-08-13 12:00:00.000000Z]
    }

    html =
      render_component(&ConnectAgentDrawer.connect_agent_drawer/1,
        open: true,
        tokens: [token]
      )

    assert html =~ "my laptop"
    assert html =~ ~s(phx-click="connect:revoke")
    assert html =~ ~s(phx-value-id="tok-123")
  end
end
