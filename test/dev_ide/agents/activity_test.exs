defmodule DevIDE.Agents.ActivityTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Agents.Activity

  setup do
    Activity.clear()
    on_exit(fn -> Activity.clear() end)
    :ok
  end

  test "records and returns recent MCP activity per workspace" do
    entry =
      Activity.record(%{
        workspace_id: "ws-alpha",
        source: :terminal_mcp,
        tool: "terminal_capture",
        summary: "session=devide_alpha_u-1",
        status: :ok
      })

    assert entry.tool == "terminal_capture"
    assert entry.metadata == %{}
    assert length(Activity.recent("ws-alpha")) == 1
    assert Activity.recent("other") == []
  end

  test "keeps structured metadata for pane-level indicators" do
    entry =
      Activity.record(%{
        workspace_id: "ws-alpha",
        source: :terminal_mcp,
        tool: "terminal_send_command",
        summary: "session=devide_alpha_u-dev · pane=%3",
        metadata: %{session: "devide_alpha_u-dev", pane: "%3"},
        status: :ok
      })

    assert entry.metadata == %{session: "devide_alpha_u-dev", pane: "%3"}
  end

  test "broadcasts activity to subscribers" do
    Activity.subscribe("ws-broadcast")

    Activity.record(%{
      workspace_id: "ws-broadcast",
      source: :preview_mcp,
      tool: "preview_observe",
      summary: "session 1",
      status: :ok
    })

    assert_receive {:agent_mcp_activity, %{tool: "preview_observe"}}
  end
end
