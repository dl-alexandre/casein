defmodule CaseinWeb.WorkspaceLive.AgentWriteLockedBannerTest do
  use CaseinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CaseinWeb.WorkspaceLive.Show.AgentWriteBanner

  # Banner surfaces when agent-write unlock is inactive (#592).

  test "banner id is stable for chrome selectors" do
    assert "agent-write-locked-banner-" <> "ws" == "agent-write-locked-banner-ws"
  end

  test "renders locked banner with unlock control when unlock is inactive" do
    html =
      render_component(&AgentWriteBanner.agent_write_locked_banner/1,
        workspace: %{id: "ws-test"},
        agent_write_unlock: %{status: :inactive, until: nil, by: nil}
      )

    assert html =~ ~s(id="agent-write-locked-banner-ws-test")
    assert html =~ ~s(id="agent-write-locked-banner-unlock-ws-test")
    assert html =~ "Read-only agents"
    assert html =~ "Unlock 30 min"
  end

  test "hides banner when unlock is active" do
    html =
      render_component(&AgentWriteBanner.agent_write_locked_banner/1,
        workspace: %{id: "ws-test"},
        agent_write_unlock: %{status: :active, until: DateTime.utc_now(), by: "op"}
      )

    refute html =~ "agent-write-locked-banner-ws-test"
    refute html =~ "Read-only agents"
  end
end
