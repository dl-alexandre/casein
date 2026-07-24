defmodule Casein.Runs.LedgerTest do
  use Casein.TestCase, async: false

  alias Casein.Audit
  alias Casein.Policy.Decision
  alias Casein.Runs.Ledger

  setup do
    Audit.clear()
    :ok
  end

  test "records raw session attach in the canonical ledger envelope" do
    decision = Decision.allow(:use_raw_terminal, :manual, %{workspace_id: "ws-1"})

    Ledger.raw_session_attached(decision, %{
      workspace_id: "ws-1",
      actor_id: "dev",
      session_id: "tab-1",
      metadata: %{"host_id" => "local", "terminal_mode" => "raw"}
    })

    [event] = Ledger.recent_for("ws-1", 10)

    assert event.action == "run.session_attached"
    assert event.target_type == "session"
    assert event.target_ref == "tab-1"
    assert event.metadata["noun"] == "session"
    assert event.metadata["plane"] == "raw"
    assert event.metadata["ledger"] == "run"
    assert event.metadata["ledger_version"] == 1
  end

  test "records run lifecycle and reconstructs a run summary" do
    run_id = Ledger.new_run_id()

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
    assert summary.started_at
    assert summary.finished_at

    assert ["run.started", "run.succeeded"] =
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
