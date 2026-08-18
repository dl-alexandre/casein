defmodule Casein.Agents.GrokCapabilityPolicyTest do
  use Casein.DataCase, async: false

  alias Casein.Agents.GrokCapabilityPolicy
  alias Casein.Workspaces
  alias Casein.Workspaces.DbIsolation

  @workspace_id "grok-policy-ws"

  setup do
    insert(:workspace_record, external_id: @workspace_id, name: @workspace_id, mode: "manual")
    assert {:ok, _record} = persist_isolation(:unknown)
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
    assert "worktree_status" in snapshot.allowed_tools["terminal"]
    assert "worktree_changed_paths" in snapshot.allowed_tools["terminal"]
    assert "worktree_diff" in snapshot.allowed_tools["terminal"]
    assert "runtime_signal" in snapshot.allowed_tools["terminal"]
    assert "annotation_propose" in snapshot.allowed_tools["terminal"]
    # worker_launch / worker_cancel are medium mutations — locked grants must not see them
    refute "worker_launch" in snapshot.allowed_tools["terminal"]
    refute "worker_cancel" in snapshot.allowed_tools["terminal"]
    refute "terminal_send_command" in snapshot.allowed_tools["terminal"]
    refute "terminal_send_agent_command" in snapshot.allowed_tools["terminal"]
    refute "artifact_create" in snapshot.allowed_tools["artifact"]
  end

  test "known isolation grants mutations including raw send; unknown isolation removes them" do
    assert {:ok, _record} = persist_isolation(:ephemeral)

    issued = GrokCapabilityPolicy.snapshot(@workspace_id)
    assert issued.write_enabled
    assert "terminal_send_agent_command" in issued.allowed_tools["terminal"]
    assert "terminal_send_command" in issued.allowed_tools["terminal"]
    assert "terminal_send_keys" in issued.allowed_tools["terminal"]
    assert "artifact_create" in issued.allowed_tools["artifact"]

    # Ceiling was issued with full write set; unknown isolation fails closed.
    ceiling = GrokCapabilityPolicy.tool_ceiling()
    assert {:ok, _record} = persist_isolation(:unknown)

    claims = %{workspace_id: @workspace_id, allowed_tools: ceiling}
    assert {:ok, effective, current} = GrokCapabilityPolicy.effective_tools(claims)
    refute current.write_enabled
    refute "terminal_send_agent_command" in effective["terminal"]
    refute "terminal_send_command" in effective["terminal"]
    refute "artifact_create" in effective["artifact"]
    assert "terminal_list_sessions" in effective["terminal"]
  end

  test "known isolation after issue expands effective tools without re-minting" do
    ceiling = GrokCapabilityPolicy.tool_ceiling()
    claims = %{workspace_id: @workspace_id, allowed_tools: ceiling}

    assert {:ok, locked, _} = GrokCapabilityPolicy.effective_tools(claims)
    refute "terminal_send_command" in locked["terminal"]

    assert {:ok, _} = persist_isolation(:local)

    assert {:ok, unlocked, current} = GrokCapabilityPolicy.effective_tools(claims)
    assert current.write_enabled
    assert "terminal_send_command" in unlocked["terminal"]
    assert "terminal_send_agent_command" in unlocked["terminal"]
  end

  defp persist_isolation(isolation) do
    Workspaces.State.persist_isolation(
      @workspace_id,
      %DbIsolation{isolation: isolation, source: :default, detected_at: DateTime.utc_now()}
    )
  end
end
