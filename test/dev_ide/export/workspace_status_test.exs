defmodule DevIDE.Export.WorkspaceStatusTest do
  use ExUnit.Case, async: false

  alias DevIDE.Audit
  alias DevIDE.Commands.History
  alias DevIDE.Export.WorkspaceStatus
  alias DevIDE.Runs.Ledger
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    Audit.clear()
    History.MemoryAdapter.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      History.MemoryAdapter.clear()
    end)

    {:ok, _} =
      State.sync(%Workspace{
        id: "ws-deploy",
        name: "deploy-test",
        user: "alice",
        branch: "main",
        status: :running,
        path: nil,
        metadata: %{}
      })

    :ok
  end

  test "status includes deploy summary from deployment health" do
    assert {:ok, payload} = WorkspaceStatus.status("ws-deploy")
    assert is_map(payload.deploy)
    assert is_binary(payload.deploy.running_revision)
    assert is_boolean(payload.deploy.ok)
    assert is_map(payload.deploy.checks)
    assert Map.has_key?(payload.deploy.checks, :deploy_revision_current)
  end

  test "status returns :error for unknown workspace" do
    assert WorkspaceStatus.status("missing-workspace") == :error
    assert WorkspaceStatus.status(nil) == :error
  end

  test "list_summary returns synced workspace summaries" do
    summaries = WorkspaceStatus.list_summary()
    assert [%{id: "ws-deploy", name: "deploy-test"} | _] = summaries
  end

  test "deploy summary includes socket fields from health status" do
    assert {:ok, payload} = WorkspaceStatus.status("ws-deploy")
    assert Map.has_key?(payload.deploy, :socket_path)
    assert Map.has_key?(payload.deploy, :current_socket)
  end

  test "runs/1 returns ledger-backed run summaries" do
    run_id = seed_run!()

    assert {:ok, runs} = WorkspaceStatus.runs("ws-deploy")
    assert [%{id: ^run_id, command_id: "format", status: "succeeded"} | _] = runs
    assert WorkspaceStatus.runs("missing") == :error
  end

  test "run/2 returns timeline, artifacts, and scrubbed summary" do
    run_id = seed_run!()

    {:ok, record} =
      History.start_run(%{workspace_id: "ws-deploy", command_id: "format", id: run_id})

    assert {:ok, _} =
             History.finish_run(record.id, %{status: :succeeded, exit_code: 0, output: "ok\n"})

    assert {:ok, payload} = WorkspaceStatus.run("ws-deploy", run_id)
    assert payload.id == run_id
    assert payload.workspace_id == "ws-deploy"
    assert payload.summary.command_id == "format"

    assert Enum.map(payload.timeline, & &1.action) == [
             "run.command_requested",
             "run.started",
             "run.succeeded"
           ]

    assert [%{type: "command_output", output: "ok\n"}] = payload.artifacts
    assert WorkspaceStatus.run("ws-deploy", "missing-run") == :error
  end

  test "proposals/1 returns an empty list without host_path and discovers files when present" do
    assert {:ok, []} = WorkspaceStatus.proposals("ws-deploy")

    root = proposal_root!()

    {:ok, _} =
      State.sync(%Workspace{
        id: "ws-proposals",
        name: "proposals-test",
        user: "alice",
        branch: "main",
        status: :running,
        path: root,
        metadata: %{}
      })

    base = Path.join([root, ".opencode", "proposals"])
    File.mkdir_p!(base)
    File.write!(Path.join(base, "fix.diff"), "--- a/x\n+++ b/x\n")

    assert {:ok, [%{path: ".opencode/proposals/fix.diff"} | _]} =
             WorkspaceStatus.proposals("ws-proposals")

    assert WorkspaceStatus.proposals("missing") == :error
  end

  test "audit/1 returns recent audit events with ledger metadata" do
    {:ok, event} =
      Audit.emit(%{
        workspace_id: "ws-deploy",
        actor_id: "agent-1",
        action: "terminal.command_sent",
        target_type: "tmux_session",
        target_ref: "devide_alpha_main"
      })

    assert {:ok, [audit_entry | _]} = WorkspaceStatus.audit("ws-deploy")
    assert audit_entry.id == event.id
    assert audit_entry.action == "terminal.command_sent"
    assert audit_entry.inserted_at
    assert WorkspaceStatus.audit("missing") == :error
  end

  defp seed_run! do
    run_id = Ledger.new_run_id()

    Ledger.command_requested(%{
      workspace_id: "ws-deploy",
      actor_id: "dev",
      command_id: "format",
      run_id: run_id,
      plane: "safe_action"
    })

    Ledger.run_started(%{
      workspace_id: "ws-deploy",
      actor_id: "dev",
      command_id: "format",
      run_id: run_id
    })

    Ledger.run_finished(:succeeded, %{
      workspace_id: "ws-deploy",
      actor_id: "dev",
      command_id: "format",
      run_id: run_id,
      metadata: %{exit_code: 0}
    })

    run_id
  end

  defp proposal_root! do
    root =
      Path.join(System.tmp_dir!(), "ws-status-proposals-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
