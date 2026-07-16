defmodule DevIDE.Agents.GrokCapabilityPolicyTest do
  use DevIDE.DataCase, async: false

  alias DevIDE.Agents.GrokCapabilityPolicy
  alias DevIDE.Workspaces

  @workspace_id "grok-policy-ws"

  setup do
    insert(:workspace_record, external_id: @workspace_id, name: @workspace_id, mode: "manual")
    :ok
  end

  test "every direct DevIDE MCP tool has explicit mutation metadata" do
    assert GrokCapabilityPolicy.classified?()
  end

  test "locked workspaces grant reads and reporting, not execution or artifact writes" do
    snapshot = GrokCapabilityPolicy.snapshot(@workspace_id)

    assert snapshot.mode == "manual"
    refute snapshot.write_enabled
    assert "terminal_list_sessions" in snapshot.allowed_tools["terminal"]
    assert "terminal_report_agent_state" in snapshot.allowed_tools["terminal"]
    assert "annotation_propose" in snapshot.allowed_tools["terminal"]
    refute "terminal_send_command" in snapshot.allowed_tools["terminal"]
    refute "artifact_create" in snapshot.allowed_tools["artifact"]
  end

  test "write unlock grants mutations and live revocation removes them" do
    until = DateTime.add(DateTime.utc_now(), 300, :second)
    assert {:ok, _record} = Workspaces.grant_agent_write_unlock(@workspace_id, until, "operator")

    issued = GrokCapabilityPolicy.snapshot(@workspace_id)
    assert issued.write_enabled
    assert "terminal_send_agent_command" in issued.allowed_tools["terminal"]
    refute "terminal_send_command" in issued.allowed_tools["terminal"]
    refute "terminal_send_keys" in issued.allowed_tools["terminal"]
    assert "artifact_create" in issued.allowed_tools["artifact"]

    assert {:ok, _record} = Workspaces.revoke_agent_write_unlock(@workspace_id)

    claims = %{workspace_id: @workspace_id, allowed_tools: issued.allowed_tools}
    assert {:ok, effective, current} = GrokCapabilityPolicy.effective_tools(claims)
    refute current.write_enabled
    refute "terminal_send_agent_command" in effective["terminal"]
    refute "artifact_create" in effective["artifact"]
  end
end
