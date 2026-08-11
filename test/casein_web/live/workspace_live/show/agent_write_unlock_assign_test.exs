defmodule CaseinWeb.WorkspaceLive.Show.AgentWriteUnlockAssignTest do
  # The chrome banner has two conditions — unlock inactive AND a capability-scoped
  # agent bound — and both are computed here. A component test can only prove the
  # markup honours the flag; this proves the flag tracks the capability table.
  use Casein.DataCase, async: false

  alias Casein.Agents.AgentCapabilityTokens
  alias Casein.Workspaces.State.MemoryAdapter
  alias CaseinWeb.WorkspaceLive.Show

  @workspace_id "ws-capability-assign"
  @leader_id "0123456789abcdef01234567"

  setup do
    MemoryAdapter.clear()
    on_exit(&MemoryAdapter.clear/0)
    :ok
  end

  defp socket, do: %Phoenix.LiveView.Socket{}

  defp mint! do
    {:ok, _raw, record} =
      AgentCapabilityTokens.create_for_grok(%{
        workspace_id: @workspace_id,
        runtime: "grok",
        tmux_session_id: "casein_" <> @workspace_id <> "_agent-1",
        pane_id: "%1",
        leader_id: @leader_id,
        bundle_digest: String.duplicate("a", 64),
        workspace_mode: "manual",
        allowed_tools: %{"terminal" => ["terminal_capture"]}
      })

    record
  end

  test "capability_bound is false when only ungated runtimes are in the workspace" do
    assigns = Show.assign_agent_write_unlock(socket(), @workspace_id).assigns

    assert assigns.agent_write_unlock.status == :inactive
    refute assigns.agent_write_unlock.capability_bound
  end

  test "capability_bound follows the workspace's live capabilities" do
    record = mint!()

    assert Show.assign_agent_write_unlock(socket(), @workspace_id).assigns.agent_write_unlock.capability_bound

    # Another workspace's capability must not bind this one.
    refute Show.assign_agent_write_unlock(socket(), "ws-elsewhere").assigns.agent_write_unlock.capability_bound

    {:ok, _} = AgentCapabilityTokens.revoke(record.id, @workspace_id)

    refute Show.assign_agent_write_unlock(socket(), @workspace_id).assigns.agent_write_unlock.capability_bound
  end

  test "unlock status and capability binding are independent" do
    mint!()
    until = DateTime.add(DateTime.utc_now(), 1800, :second)
    {:ok, _} = Casein.Workspaces.grant_agent_write_unlock(@workspace_id, until, "operator")

    unlock = Show.assign_agent_write_unlock(socket(), @workspace_id).assigns.agent_write_unlock

    assert unlock.status == :active
    assert unlock.by == "operator"
    assert unlock.capability_bound
  end
end
