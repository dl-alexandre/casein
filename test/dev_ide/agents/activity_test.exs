defmodule DevIDE.Agents.ActivityTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Agents.{Activity, AgentEvents}

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

  test "accepts normalized Grok ACP activity as a workspace feed source" do
    entry =
      Activity.record(%{
        workspace_id: "ws-grok",
        source: :grok_acp,
        tool: "grok_plan",
        summary: "Plan updated · 3 steps",
        metadata: %{session_id: "sess-1", step_count: 3},
        status: :ok
      })

    assert entry.source == :grok_acp
    assert [^entry] = Activity.recent("ws-grok")
  end

  test "hydrates the live feed from the durable AgentEvent projection" do
    assert {:ok, event, :inserted} =
             AgentEvents.append_runtime(%{
               workspace_id: "ws-durable-feed",
               producer: "grok",
               ingress: "acp",
               agent_session_id: "sess-durable",
               source_event_id: "plan-1",
               event_type: "plan.updated",
               summary: "Plan updated · 2 steps",
               payload: %{schema_version: 1, step_count: 2}
             })

    assert [entry] = Activity.recent("ws-durable-feed")
    assert entry.id == event.id
    assert entry.source == :agent_event
    assert entry.tool == "plan.updated"
    assert entry.metadata.agent_session_id == "sess-durable"
    assert entry.metadata["step_count"] == 2
  end
end
