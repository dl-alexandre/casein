defmodule DevIDE.Terminals.BoundaryTest do
  use ExUnit.Case, async: false

  alias DevIDE.Audit
  alias DevIDE.Devbox.Workspace
  alias DevIDE.Runners
  alias DevIDE.Terminals.Boundary
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    Runners.clear()
    Audit.clear()

    prev_default = Application.get_env(:dev_ide, :default_workspace_mode)
    prev_overrides = Application.get_env(:dev_ide, :workspace_modes)

    Application.put_env(:dev_ide, :default_workspace_mode, :review)
    Application.delete_env(:dev_ide, :workspace_modes)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runners.clear()
      Audit.clear()
      restore(:default_workspace_mode, prev_default)
      restore(:workspace_modes, prev_overrides)
    end)

    seed_workspace("ws-1")
    :ok
  end

  test "governed terminal resolves only allowlisted safe commands" do
    assert {:ok, "test"} = Boundary.resolve_command("mix test")
    assert {:ok, "test"} = Boundary.resolve_command("mix test --color")
    assert {:ok, "compile"} = Boundary.resolve_command("compile")
    assert {:ok, "format"} = Boundary.resolve_command("mix format --check-formatted")

    assert {:error, :not_allowed} = Boundary.resolve_command("mix format")
    assert {:error, :not_allowed} = Boundary.resolve_command("mix test test/foo_test.exs")
    assert {:error, :not_allowed} = Boundary.resolve_command("rm -rf priv/")
  end

  test "allowed governed terminal command enqueues runner assignment and audits allow" do
    assert {:ok, assignment} =
             Boundary.submit_governed("ws-1", "mix test", actor_id: "user-1")

    assert assignment.safe_action_id == "command:test"
    assert assignment.status == "queued"
    assert assignment.action.argv == ["mix", "test", "--color"]

    [event] = Audit.recent_for("ws-1", 5)
    assert event.action == "runner.assignment_queued"
    assert event.decision == :allow
    assert event.target_ref == "command:test"
    assert event.metadata.command_id == "test"
  end

  test "denied governed terminal command creates policy audit row" do
    assert {:error, :not_allowed} =
             Boundary.submit_governed("ws-1", "rm -rf priv/", actor_id: "user-1")

    [event] = Audit.recent_for("ws-1", 5)
    assert event.action == "policy.blocked"
    assert event.decision == :deny
    assert event.reason == :not_allowed
    assert event.target_type == "terminal_command"
    assert event.target_ref == "rm -rf priv/"
    assert event.metadata["terminal_mode"] == "governed"
  end

  test "raw terminal requires persisted manual mode on the local host" do
    refute Boundary.raw_allowed?("ws-1", "local")
    assert {:error, :requires_manual_mode} = Boundary.authorize_raw("ws-1", host_id: "local")

    Audit.clear()
    {:ok, _} = State.set_mode("ws-1", :manual)

    assert Boundary.raw_allowed?("ws-1", "local")
    assert :ok = Boundary.authorize_raw("ws-1", actor_id: "user-1", host_id: "local")
    assert {:error, :requires_local_host} = Boundary.authorize_raw("ws-1", host_id: "remote")

    [denied, allowed] = Audit.recent_for("ws-1", 5)
    assert denied.action == "policy.blocked"
    assert denied.reason == :requires_local_host
    assert allowed.action == "terminal.raw_attached"
    assert allowed.decision == :allow
  end

  defp seed_workspace(id) do
    {:ok, _} =
      State.sync_from_manager(%Workspace{
        id: id,
        name: "alpha",
        user: "alice",
        branch: "main",
        type: :v3,
        status: :running,
        path: "/tmp/#{id}",
        raw: %{"id" => id}
      })
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)
end
