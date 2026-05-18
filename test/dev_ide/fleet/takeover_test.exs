defmodule DevIDE.Fleet.TakeoverTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Assignments.EventStore.MemoryAdapter, as: EventStore
  alias DevIDE.Assignments.ProjectionStore.MemoryAdapter, as: ProjectionStore
  alias DevIDE.Audit
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore

  setup do
    EventStore.clear()
    ProjectionStore.clear()
    Audit.clear()
    ExecutionProjectionStore.clear()
    ArtifactStore.clear()

    Application.put_env(:dev_ide, :assignment_event_store_adapter, EventStore)
    Application.put_env(:dev_ide, :assignment_projection_store_adapter, ProjectionStore)
    Application.put_env(:dev_ide, :fake_tmux_test_pid, self())

    on_exit(fn ->
      EventStore.clear()
      ProjectionStore.clear()
      Audit.clear()
      ExecutionProjectionStore.clear()
      ArtifactStore.clear()
      Application.delete_env(:dev_ide, :assignment_event_store_adapter)
      Application.delete_env(:dev_ide, :assignment_projection_store_adapter)
      Application.delete_env(:dev_ide, :fake_tmux_test_pid)
    end)

    :ok
  end

  test "prepare_takeover returns attach instructions and evidence without mutating assignment state" do
    {:ok, assignment} = Assignments.create(%{workspace_id: "ws-takeover"})
    {:ok, _claimed} = Assignments.claim(assignment.id, "runner-1")
    {:ok, running} = Assignments.start(assignment.id)

    projection = %ExecutionProjection{
      id: "exec-1",
      assignment_id: assignment.id,
      runner_id: "runner-1",
      lease_id: "lease-1",
      state: :started,
      workspace_id: "ws-takeover",
      worktree_path: "/tmp/ws-takeover",
      tmux_session: "alive-session",
      started_at: DateTime.utc_now()
    }

    :ok = ExecutionProjectionStore.create(projection)
    :ok = ArtifactStore.append_chunk("exec-1", "stdout", "build output\n", DateTime.utc_now())

    assert {:ok, takeover} =
             Fleet.prepare_takeover(assignment.id,
               operator_id: "operator-1",
               tmux_adapter: DevIDE.Test.FakeTmuxAdapter
             )

    assert takeover.assignment_id == assignment.id
    assert takeover.workspace_id == "ws-takeover"
    assert takeover.assignment_state == "running"
    assert takeover.execution == projection
    assert takeover.tmux_session == "alive-session"
    assert takeover.attach_command == "tmux attach -t alive-session"
    assert takeover.pane_snapshot == "captured pane\n"
    assert [%{stream: "stdout", data: "build output\n"} = chunk] = takeover.historical_chunks
    assert chunk.byte_size == byte_size("build output\n")

    assert takeover.orchestration_state_unchanged?

    assert {:ok, after_takeover} = Assignments.get(assignment.id)
    assert after_takeover == running

    [event] = Audit.recent_for("ws-takeover", 1)
    assert event.action == "fleet.operator_takeover.prepared"
    assert event.actor_id == "operator-1"
    assert event.target_ref == assignment.id
    assert event.metadata.execution_id == "exec-1"
    assert event.metadata.orchestration_state_unchanged == true
  end

  test "takeover_send_keys lets an operator intervene without mutating assignment state" do
    {:ok, assignment} = Assignments.create(%{workspace_id: "ws-takeover"})
    {:ok, _claimed} = Assignments.claim(assignment.id, "runner-1")
    {:ok, running} = Assignments.start(assignment.id)
    {:ok, approval} = grant_approval(:takeover_send_keys, assignment.id)

    :ok =
      ExecutionProjectionStore.create(%ExecutionProjection{
        id: "exec-keys",
        assignment_id: assignment.id,
        runner_id: "runner-1",
        lease_id: "lease-1",
        state: :started,
        workspace_id: "ws-takeover",
        tmux_session: "alive-session",
        started_at: DateTime.utc_now()
      })

    assert {:ok, intervention} =
             Fleet.takeover_send_keys(assignment.id, "mix test",
               operator_id: "operator-1",
               approval_id: approval.id,
               tmux_adapter: DevIDE.Test.FakeTmuxAdapter
             )

    assert_receive {:fake_tmux_keys, "alive-session", "mix test"}

    assert intervention.assignment_id == assignment.id
    assert intervention.execution_id == "exec-keys"
    assert intervention.sent
    assert intervention.orchestration_state_unchanged?

    assert {:ok, after_intervention} = Assignments.get(assignment.id)
    assert after_intervention == running

    [event] = Audit.recent_for("ws-takeover", 1)
    assert event.action == "fleet.operator_takeover.intervened"
    assert event.target_ref == assignment.id
    assert event.metadata.command_id == "test"
    assert event.metadata.takeover_mode == :governed
    assert event.metadata.orchestration_state_unchanged == true
  end

  test "takeover_send_keys requires explicit approval" do
    {:ok, assignment} = Assignments.create(%{workspace_id: "ws-takeover"})
    {:ok, _claimed} = Assignments.claim(assignment.id, "runner-1")
    {:ok, _running} = Assignments.start(assignment.id)

    :ok =
      ExecutionProjectionStore.create(%ExecutionProjection{
        id: "exec-needs-approval",
        assignment_id: assignment.id,
        runner_id: "runner-1",
        lease_id: "lease-1",
        state: :started,
        workspace_id: "ws-takeover",
        tmux_session: "alive-session",
        started_at: DateTime.utc_now()
      })

    assert {:error, :approval_required} =
             Fleet.takeover_send_keys(assignment.id, "mix test",
               operator_id: "operator-1",
               tmux_adapter: DevIDE.Test.FakeTmuxAdapter
             )

    refute_receive {:fake_tmux_keys, "alive-session", "mix test"}
  end

  test "takeover_send_keys rejects non-allowlisted command input" do
    {:ok, assignment} = Assignments.create(%{workspace_id: "ws-takeover"})
    {:ok, _claimed} = Assignments.claim(assignment.id, "runner-1")
    {:ok, running} = Assignments.start(assignment.id)
    {:ok, approval} = grant_approval(:takeover_send_keys, assignment.id)

    :ok =
      ExecutionProjectionStore.create(%ExecutionProjection{
        id: "exec-denied",
        assignment_id: assignment.id,
        runner_id: "runner-1",
        lease_id: "lease-1",
        state: :started,
        workspace_id: "ws-takeover",
        tmux_session: "alive-session",
        started_at: DateTime.utc_now()
      })

    assert {:error, :not_allowed} =
             Fleet.takeover_send_keys(assignment.id, "rm -rf /",
               operator_id: "operator-1",
               approval_id: approval.id,
               tmux_adapter: DevIDE.Test.FakeTmuxAdapter
             )

    refute_receive {:fake_tmux_keys, "alive-session", "rm -rf /"}

    assert {:ok, after_intervention} = Assignments.get(assignment.id)
    assert after_intervention == running

    [event] = Audit.recent_for("ws-takeover", 1)
    assert event.action == "fleet.operator_takeover.denied"
    assert event.decision == :deny
    assert event.reason == :not_allowed
    assert event.target_ref == assignment.id
  end

  test "raw takeover mode is policy gated" do
    {:ok, assignment} = Assignments.create(%{workspace_id: "ws-takeover"})
    {:ok, _claimed} = Assignments.claim(assignment.id, "runner-1")
    {:ok, running} = Assignments.start(assignment.id)
    {:ok, approval} = grant_approval(:takeover_send_keys, assignment.id)

    :ok =
      ExecutionProjectionStore.create(%ExecutionProjection{
        id: "exec-raw-denied",
        assignment_id: assignment.id,
        runner_id: "runner-1",
        lease_id: "lease-1",
        state: :started,
        workspace_id: "ws-takeover",
        tmux_session: "alive-session",
        started_at: DateTime.utc_now()
      })

    assert {:error, :requires_local_host} =
             Fleet.takeover_send_keys(assignment.id, "C-c",
               mode: :raw,
               operator_id: "operator-1",
               approval_id: approval.id,
               tmux_adapter: DevIDE.Test.FakeTmuxAdapter
             )

    refute_receive {:fake_tmux_keys, "alive-session", "C-c"}

    assert {:ok, after_intervention} = Assignments.get(assignment.id)
    assert after_intervention == running
  end

  test "prepare_takeover refuses inactive or missing tmux sessions" do
    {:ok, assignment} = Assignments.create(%{workspace_id: "ws-takeover"})

    assert {:error, :no_active_execution} =
             Fleet.prepare_takeover(assignment.id, tmux_adapter: DevIDE.Test.FakeTmuxAdapter)

    :ok =
      ExecutionProjectionStore.create(%ExecutionProjection{
        id: "exec-2",
        assignment_id: assignment.id,
        runner_id: "runner-1",
        lease_id: "lease-1",
        state: :started,
        tmux_session: "dead-session"
      })

    assert {:error, :session_not_alive} =
             Fleet.prepare_takeover(assignment.id, tmux_adapter: DevIDE.Test.FakeTmuxAdapter)
  end

  defp grant_approval(action, assignment_id) do
    {:ok, approval} =
      Fleet.request_approval(
        action,
        %{type: "assignment", ref: assignment_id, workspace_id: "ws-takeover"},
        actor_id: "operator-1"
      )

    Fleet.grant_approval(approval.id, actor_id: "approver-1")
  end
end
