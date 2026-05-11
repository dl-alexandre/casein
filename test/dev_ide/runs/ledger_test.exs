defmodule DevIDE.Runs.LedgerTest do
  use ExUnit.Case, async: false

  alias DevIDE.Audit
  alias DevIDE.Policy.Decision
  alias DevIDE.Runners.Assignment
  alias DevIDE.Runs.Ledger

  setup do
    Audit.clear()
    :ok
  end

  test "records command, run, and assignment events in the canonical ledger envelope" do
    decision = Decision.allow(:run_command, :review, %{workspace_id: "ws-1"})
    run_id = Ledger.new_run_id()

    Ledger.command_requested(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      session_id: "tab-1",
      command_id: "test",
      command_line: "mix test",
      run_id: run_id,
      plane: "governed"
    })

    assignment = %Assignment{
      id: "assignment-1",
      workspace_id: "ws-1",
      safe_action_id: "command:test",
      safe_action_version: 1,
      status: "queued",
      queued_at: DateTime.utc_now(),
      requested_by: "dev",
      metadata: %{"run_id" => run_id}
    }

    Ledger.run_queued(decision, assignment, %{actor_id: "dev"})

    Ledger.assignment_claimed(
      %{assignment | status: "claimed", claimed_by: "runner-a"},
      "runner-a"
    )

    [claimed, queued, requested] = Ledger.recent_for("ws-1", 10)

    assert claimed.action == "run.assignment_claimed"
    assert claimed.target_type == "assignment"
    assert claimed.metadata["noun"] == "assignment"
    assert claimed.metadata["run_id"] == run_id

    assert queued.action == "run.queued"
    assert queued.target_type == "run"
    assert queued.target_ref == run_id
    assert queued.metadata["assignment_id"] == "assignment-1"
    assert queued.metadata["ledger"] == "run"
    assert queued.metadata["ledger_version"] == 1

    assert requested.action == "run.command_requested"
    assert requested.target_type == "command"
    assert requested.target_ref == "test"
    assert requested.metadata["session_id"] == "tab-1"
  end

  test "records denials without falling back to policy.blocked" do
    decision = Decision.deny(:run_command, :review, :not_allowed, %{workspace_id: "ws-1"})

    Ledger.command_denied(decision, %{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_line: "rm -rf priv/",
      run_id: "run-1",
      plane: "governed"
    })

    [event] = Ledger.recent_for("ws-1", 10)
    assert event.action == "run.command_denied"
    assert event.decision == :deny
    assert event.reason == :not_allowed
    assert event.metadata["policy_mode"] == "review"
  end

  test "records immediate run lifecycle and reconstructs a run summary" do
    run_id = Ledger.new_run_id()

    Ledger.command_requested(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "format",
      run_id: run_id,
      plane: "safe_action",
      metadata: %{source: "ui", protocol: "devide.immediate.v1"}
    })

    Ledger.run_started(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "format",
      run_id: run_id,
      metadata: %{argv: ["mix", "format", "--check-formatted"]}
    })

    Ledger.run_finished(:succeeded, %{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "format",
      run_id: run_id,
      metadata: %{exit_code: 0}
    })

    [summary] = Ledger.recent_runs_for("ws-1", 10)

    assert summary.id == run_id
    assert summary.command_id == "format"
    assert summary.status == "succeeded"
    assert summary.exit_code == 0
    assert summary.requested_at
    assert summary.started_at
    assert summary.finished_at

    assert ["run.command_requested", "run.started", "run.succeeded"] =
             Ledger.timeline_for("ws-1", run_id) |> Enum.map(& &1.action)
  end

  test "records approval events as run lifecycle events" do
    run_id = Ledger.new_run_id()

    Ledger.approval_requested(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      run_id: run_id,
      command_id: "compile",
      metadata: %{approval_id: "approval-1"}
    })

    Ledger.approval_granted(%{
      workspace_id: "ws-1",
      actor_id: "reviewer",
      run_id: run_id,
      command_id: "compile",
      metadata: %{approval_id: "approval-1"}
    })

    [granted, requested] = Ledger.timeline_for("ws-1", run_id) |> Enum.reverse()

    assert granted.action == "run.approval_granted"
    assert granted.metadata["approval_status"] == "granted"
    assert requested.action == "run.approval_requested"
    assert requested.metadata["approval_status"] == "requested"
  end
end
