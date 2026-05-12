defmodule DevIDE.Fleet.OperatorWorkflowTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Audit
  alias DevIDE.Commands.History.MemoryAdapter, as: CommandHistory
  alias DevIDE.Devbox.Workspace
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.OperatorNotifications
  alias DevIDE.Fleet.OutputStream
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter, as: WorkspaceState

  setup do
    previous_adapter = Application.get_env(:dev_ide, :commands_adapter)
    previous_test_pid = Application.get_env(:dev_ide, :fake_command_test_pid)

    Application.put_env(:dev_ide, :commands_adapter, DevIDE.Test.FakeFailingCommandAdapter)
    Application.put_env(:dev_ide, :fake_command_test_pid, self())

    Fleet.clear()
    DevIDE.Fleet.Queue.clear()
    Assignments.clear()
    OutputStream.clear()
    ExecutionProjectionStore.clear()
    ArtifactStore.clear()
    WorkspaceState.clear()
    CommandHistory.clear()
    Audit.clear()
    OperatorNotifications.clear()

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      Assignments.clear()
      OutputStream.clear()
      ExecutionProjectionStore.clear()
      ArtifactStore.clear()
      WorkspaceState.clear()
      CommandHistory.clear()
      Audit.clear()
      OperatorNotifications.clear()

      if previous_adapter do
        Application.put_env(:dev_ide, :commands_adapter, previous_adapter)
      else
        Application.delete_env(:dev_ide, :commands_adapter)
      end

      if previous_test_pid do
        Application.put_env(:dev_ide, :fake_command_test_pid, previous_test_pid)
      else
        Application.delete_env(:dev_ide, :fake_command_test_pid)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "operator flow reviews a failed delegation, approves recovery, reruns, and completes",
       %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)

    {:ok, _runner} =
      Fleet.register(%{hostname: "operator-runner", capabilities: ["workspace-command:v1"]})

    assert {:ok, delegated} =
             Fleet.delegate_task("ws-operator", ["compile"],
               actor_id: "operator-1",
               task_id: "task-operator",
               timeout_ms: 1_000
             )

    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "compile"]}
    assert delegated.status == :failed

    assert {:ok, [review]} = Fleet.review_queue("ws-operator")
    assert review.task_id == "task-operator"
    assert review.status == :needs_review
    assert review.exit_status == "failed"
    assert review.command.id == "compile"
    assert [%{stream: "stderr", data: "boom\n"}] = review.artifacts
    assert review.dossier.ref =~ review.assignment_id

    proposal =
      Enum.find_value(review.recovery_options, fn
        %{type: :proposal, action: %{kind: :retry_assignment} = action} -> action
        _ -> nil
      end)

    assert proposal

    assert {:error, :approval_required} =
             Fleet.apply_approved_recovery(proposal, nil, "operator-1", rerun: true)

    {:ok, approval} =
      Fleet.request_approval(
        :retry_assignment,
        %{type: "assignment", ref: proposal.assignment_id, workspace_id: "ws-operator"},
        actor_id: "operator-1",
        reason: "retry failed delegated compile"
      )

    {:ok, granted} = Fleet.grant_approval(approval.id, actor_id: "lead-1")
    assert granted.status == "granted"

    Application.put_env(:dev_ide, :commands_adapter, DevIDE.Test.FakeCommandAdapter)

    assert {:ok, recovered} =
             Fleet.apply_approved_recovery(proposal, approval.id, "operator-1",
               rerun: true,
               timeout_ms: 1_000
             )

    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "compile"]}
    assert recovered.execution.status == :completed
    assert recovered.execution.exit_code == 0
    assert recovered.recovery_action.applied

    assert {:ok, dossier} = Fleet.dossier("ws-operator")

    assert Enum.any?(dossier.approval_decisions, &(&1.approval_id == approval.id))
    assert Enum.any?(dossier.approval_decisions, &(&1.status == "requested"))
    assert Enum.any?(dossier.approval_decisions, &(&1.status == "granted"))

    assert Enum.any?(dossier.executions, &(&1.assignment_id == review.assignment_id))
    assert Enum.any?(dossier.executions, &(&1.assignment_id == recovered.execution.assignment_id))

    notifications = Fleet.operator_notifications(limit: 10)

    assert Enum.any?(
             notifications,
             &(&1.kind == :failed and &1.assignment_id == review.assignment_id)
           )

    assert Enum.any?(
             notifications,
             &(&1.kind == :completed and &1.assignment_id == recovered.execution.assignment_id)
           )

    assert Enum.any?(
             notifications,
             &(&1.kind == :recovered and &1.assignment_id == review.assignment_id)
           )
  end

  @tag :tmp_dir
  test "runbook actions execute safe commands, inspect dossiers, and gate session attach",
       %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)
    Application.put_env(:dev_ide, :commands_adapter, DevIDE.Test.FakeCommandAdapter)

    {:ok, _runner} =
      Fleet.register(%{hostname: "runbook-runner", capabilities: ["workspace-command:v1"]})

    assert Enum.map(Fleet.runbook_actions(), & &1.id) ==
             ~w(rerun_tests rerun_precommit rebuild_assets inspect_dossier attach_session)

    assert {:ok, %{result: test_result}} =
             Fleet.runbook_action("rerun_tests", "ws-operator", timeout_ms: 1_000)

    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "test", "--color"]}
    assert test_result.status == :completed

    assert {:ok, %{result: precommit_result}} =
             Fleet.runbook_action("rerun_precommit", "ws-operator", timeout_ms: 1_000)

    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "precommit"]}
    assert precommit_result.status == :completed

    assert {:ok, %{result: assets_result}} =
             Fleet.runbook_action("rebuild_assets", "ws-operator", timeout_ms: 1_000)

    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "assets.build"]}
    assert assets_result.status == :completed

    assert {:ok, %{dossier: dossier}} = Fleet.runbook_action("inspect_dossier", "ws-operator")
    assert dossier.workspace_id == "ws-operator"

    {:ok, assignment} = Assignments.create(%{workspace_id: "ws-operator"})
    {:ok, _claimed} = Assignments.claim(assignment.id, "runner-attach")
    {:ok, _running} = Assignments.start(assignment.id)

    :ok =
      ExecutionProjectionStore.create(%ExecutionProjection{
        id: "exec-runbook-attach",
        assignment_id: assignment.id,
        runner_id: "runner-attach",
        lease_id: "lease-runbook",
        state: :started,
        workspace_id: "ws-operator",
        worktree_path: tmp_dir,
        tmux_session: "alive-session",
        started_at: DateTime.utc_now()
      })

    assert {:error, :approval_required} =
             Fleet.runbook_action("attach_session", "ws-operator",
               assignment_id: assignment.id,
               tmux_adapter: DevIDE.Test.FakeTmuxAdapter
             )

    {:ok, approval} =
      Fleet.request_approval(
        :attach_session,
        %{type: "assignment", ref: assignment.id, workspace_id: "ws-operator"},
        actor_id: "operator-1"
      )

    {:ok, _granted} = Fleet.grant_approval(approval.id, actor_id: "lead-1")

    assert {:ok, %{takeover: takeover}} =
             Fleet.runbook_action("attach_session", "ws-operator",
               assignment_id: assignment.id,
               approval_id: approval.id,
               operator_id: "operator-1",
               tmux_adapter: DevIDE.Test.FakeTmuxAdapter
             )

    assert takeover.assignment_id == assignment.id
    assert takeover.attach_command == "tmux attach -t alive-session"
  end

  @tag :tmp_dir
  test "approved recovery proposals stale out before mutation", %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)

    {:ok, assignment} = Assignments.create(%{workspace_id: "ws-operator"})
    {:ok, _claimed} = Assignments.claim(assignment.id, "runner-stale", lease_ms: -1)

    proposal =
      assignment.id
      |> DevIDE.Assignments.Recovery.propose()
      |> Enum.find(&(&1.kind == :expire_lease))

    {:ok, approval} =
      Fleet.request_approval(
        :expire_lease,
        %{type: "assignment", ref: proposal.assignment_id, workspace_id: "ws-operator"},
        actor_id: "operator-1"
      )

    {:ok, _granted} = Fleet.grant_approval(approval.id, actor_id: "lead-1")
    {:ok, _expired} = Assignments.expire(assignment.id)

    assert {:error, :stale} =
             Fleet.apply_approved_recovery(proposal, approval.id, "operator-1", rerun: false)

    assert Enum.any?(
             Fleet.operator_notifications(limit: 10),
             &(&1.kind == :stale and &1.assignment_id == proposal.assignment_id)
           )
  end

  defp seed_workspace(path) do
    {:ok, _record} =
      State.sync_from_manager(%Workspace{
        id: "ws-operator",
        name: "Operator",
        user: "operator",
        branch: "main",
        type: :v3,
        status: :running,
        path: path,
        raw: %{"id" => "ws-operator", "branch" => "main", "git_sha" => "def456"}
      })
  end
end
