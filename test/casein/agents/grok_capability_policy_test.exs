defmodule Casein.Agents.GrokCapabilityPolicyTest do
  use Casein.DataCase, async: false

  alias Casein.Agents.GrokCapabilityPolicy
  alias Casein.Workspaces

  @workspace_id "grok-policy-ws"

  setup do
    insert(:workspace_record, external_id: @workspace_id, name: @workspace_id, mode: "manual")
    assert {:ok, _record} = Workspaces.revoke_agent_write_unlock(@workspace_id)
    :ok
  end

  test "every direct Casein MCP tool has explicit mutation metadata" do
    assert GrokCapabilityPolicy.classified?()
  end

  test "tool_ceiling always includes write mutations including raw send" do
    ceiling = GrokCapabilityPolicy.tool_ceiling()

    assert "terminal_list_sessions" in ceiling["terminal"]
    assert "terminal_send_agent_command" in ceiling["terminal"]
    assert "terminal_send_command" in ceiling["terminal"]
    assert "terminal_send_keys" in ceiling["terminal"]
    assert "artifact_create" in ceiling["artifact"]
  end

  test "locked workspaces grant reads and reporting, not execution or artifact writes" do
    snapshot = GrokCapabilityPolicy.snapshot(@workspace_id)

    assert snapshot.mode == "manual"
    refute snapshot.write_enabled
    assert "terminal_list_sessions" in snapshot.allowed_tools["terminal"]
    assert "terminal_report_agent_state" in snapshot.allowed_tools["terminal"]
    assert "orchestration_status" in snapshot.allowed_tools["terminal"]
    assert "worker_status" in snapshot.allowed_tools["terminal"]
    assert "orchestration_list_workers" in snapshot.allowed_tools["terminal"]
    assert "runtime_signal" in snapshot.allowed_tools["terminal"]
    assert "annotation_propose" in snapshot.allowed_tools["terminal"]
    # worker_launch is a medium mutation — locked grants must not see it
    refute "worker_launch" in snapshot.allowed_tools["terminal"]
    refute "terminal_send_command" in snapshot.allowed_tools["terminal"]
    refute "terminal_send_agent_command" in snapshot.allowed_tools["terminal"]
    refute "artifact_create" in snapshot.allowed_tools["artifact"]
  end

  test "write unlock grants mutations including raw send; revoke removes them" do
    until = DateTime.add(DateTime.utc_now(), 300, :second)
    assert {:ok, _record} = Workspaces.grant_agent_write_unlock(@workspace_id, until, "operator")

    issued = GrokCapabilityPolicy.snapshot(@workspace_id)
    assert issued.write_enabled
    assert "terminal_send_agent_command" in issued.allowed_tools["terminal"]
    assert "terminal_send_command" in issued.allowed_tools["terminal"]
    assert "terminal_send_keys" in issued.allowed_tools["terminal"]
    assert "artifact_create" in issued.allowed_tools["artifact"]

    # Ceiling was issued with full write set; after revoke, effective shrinks.
    ceiling = GrokCapabilityPolicy.tool_ceiling()
    assert {:ok, _record} = Workspaces.revoke_agent_write_unlock(@workspace_id)

    claims = %{workspace_id: @workspace_id, allowed_tools: ceiling}
    assert {:ok, effective, current} = GrokCapabilityPolicy.effective_tools(claims)
    refute current.write_enabled
    refute "terminal_send_agent_command" in effective["terminal"]
    refute "terminal_send_command" in effective["terminal"]
    refute "artifact_create" in effective["artifact"]
    assert "terminal_list_sessions" in effective["terminal"]
  end

  test "unlock after issue expands effective tools without re-minting" do
    ceiling = GrokCapabilityPolicy.tool_ceiling()
    claims = %{workspace_id: @workspace_id, allowed_tools: ceiling}

    assert {:ok, locked, _} = GrokCapabilityPolicy.effective_tools(claims)
    refute "terminal_send_command" in locked["terminal"]

    until = DateTime.add(DateTime.utc_now(), 300, :second)
    assert {:ok, _} = Workspaces.grant_agent_write_unlock(@workspace_id, until, "operator")

    assert {:ok, unlocked, current} = GrokCapabilityPolicy.effective_tools(claims)
    assert current.write_enabled
    assert "terminal_send_command" in unlocked["terminal"]
    assert "terminal_send_agent_command" in unlocked["terminal"]
  end
end
