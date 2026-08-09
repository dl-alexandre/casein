defmodule CaseinWeb.WorkspaceLive.Show.LeaderHelpTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Casein.Agents.OrchestratorToken
  alias CaseinWeb.WorkspaceLive.Show.LeaderHelp

  test "agents tab hosts the connect mint form and empty-token state" do
    html =
      render_component(&LeaderHelp.leader_help_overlay/1,
        open: true,
        connect_tokens: []
      )

    assert html =~ "Connect an external agent"
    assert html =~ ~s(id="cheat-panel-agents")
    assert html =~ ~s(phx-submit="connect:mint")
    assert html =~ "No active tokens."
    # Agents tab selection refreshes the token list (drawer was replaced by this panel).
    assert html =~ "connect:load"
    refute html =~ "shown only once"
  end

  test "a freshly minted token is revealed with copy buttons and the config" do
    html =
      render_component(&LeaderHelp.leader_help_overlay/1,
        open: true,
        connect_new_token: "RAW-TOKEN-VALUE",
        connect_mcp_json: ~s({"mcpServers":{}}),
        connect_tokens: []
      )

    assert html =~ "shown only once"
    assert html =~ ~s(id="help-connect-copy-token")
    assert html =~ ~s(id="help-connect-copy-config")
    assert html =~ ~s(phx-hook="CopyText")
    assert html =~ "Copy .mcp.json"
    # HEEx escapes the JSON body/attribute quotes.
    assert html =~ ~s({&quot;mcpServers&quot;:{}})
    # Raw token is only on the copy control, not printed in the panel body.
    assert html =~ ~s(data-copy-text="RAW-TOKEN-VALUE")
  end

  test "existing tokens render with a scoped revoke button" do
    token = %OrchestratorToken{
      id: "tok-123",
      label: "my laptop",
      last_seen_at: ~U[2026-07-14 12:00:00.000000Z],
      expires_at: ~U[2026-08-13 12:00:00.000000Z]
    }

    html =
      render_component(&LeaderHelp.leader_help_overlay/1,
        open: true,
        connect_tokens: [token]
      )

    assert html =~ "my laptop"
    assert html =~ ~s(id="help-connect-token-tok-123")
    assert html =~ ~s(phx-click="connect:revoke")
    assert html =~ ~s(phx-value-id="tok-123")
  end

  test "connect error and info banners render when set" do
    html =
      render_component(&LeaderHelp.leader_help_overlay/1,
        open: true,
        connect_error: "Could not mint a token.",
        connect_info: "Token revoked.",
        connect_tokens: []
      )

    assert html =~ "Could not mint a token."
    assert html =~ "Token revoked."
  end
end
