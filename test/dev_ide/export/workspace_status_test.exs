defmodule DevIDE.Export.WorkspaceStatusTest do
  use ExUnit.Case, async: false

  alias DevIDE.Export.WorkspaceStatus
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    on_exit(fn -> MemoryAdapter.clear() end)

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
end
