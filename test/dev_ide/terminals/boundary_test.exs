defmodule DevIDE.Terminals.BoundaryTest do
  use ExUnit.Case, async: false

  alias DevIDE.Audit
  alias DevIDE.Workspace
  alias DevIDE.Runs.Ledger
  alias DevIDE.Terminals.Boundary
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    Audit.clear()

    prev_default = Application.get_env(:dev_ide, :default_workspace_mode)
    prev_overrides = Application.get_env(:dev_ide, :workspace_modes)
    prev_allow_raw = Application.get_env(:dev_ide, :allow_local_raw_terminal)
    prev_raw_everywhere = Application.get_env(:dev_ide, :raw_terminal_everywhere)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    root = Path.join(System.tmp_dir!(), "devide-boundary-test")
    workspace_path = Path.join(root, "ws-1")
    File.rm_rf!(root)
    File.mkdir_p!(workspace_path)
    File.write!(Path.join(workspace_path, "README.md"), "hello\n")

    Application.put_env(:dev_ide, :workspaces_root, root)
    Application.put_env(:dev_ide, :default_workspace_mode, :review)
    Application.delete_env(:dev_ide, :workspace_modes)

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      File.rm_rf(root)
      restore(:workspaces_root, prev_root)
      restore(:default_workspace_mode, prev_default)
      restore(:workspace_modes, prev_overrides)
      restore(:allow_local_raw_terminal, prev_allow_raw)
      restore(:raw_terminal_everywhere, prev_raw_everywhere)
    end)

    seed_workspace("ws-1", workspace_path)
    {:ok, workspace_path: workspace_path}
  end

  test "command examples include inspection commands" do
    examples = Boundary.command_examples()

    assert "tidewave" in examples
    assert "git status --short" in examples
  end

  test "command examples hide interactive launchers when raw shell is unavailable" do
    examples = Boundary.command_examples(raw_available?: false)

    assert "mix test" in examples
    assert "git status --short" in examples

    for command <- Boundary.interactive_command_ids() do
      refute command in examples
    end
  end

  test "command examples include interactive launchers when raw shell is available" do
    examples = Boundary.command_examples(raw_available?: true)

    for command <- Boundary.interactive_command_ids() do
      assert command in examples
    end
  end

  test "raw terminal defaults to local manual workspace access only" do
    refute Boundary.raw_allowed?("ws-1", "local")
    assert {:error, :requires_manual_mode} = Boundary.authorize_raw("ws-1", host_id: "local")

    {:ok, _} = State.set_mode("ws-1", :manual)

    assert Boundary.raw_allowed?("ws-1", "local")
    assert :ok = Boundary.authorize_raw("ws-1", actor_id: "user-1", host_id: "local")
    assert {:error, :requires_local_host} = Boundary.authorize_raw("ws-1", host_id: "remote")

    [remote_denied, allowed, mode_denied] = Ledger.recent_for("ws-1", 5)
    assert remote_denied.action == "run.session_denied"
    assert remote_denied.reason == :requires_local_host
    assert allowed.action == "run.session_attached"
    assert allowed.decision == :allow
    assert allowed.target_type == "session"
    assert mode_denied.action == "run.session_denied"
    assert mode_denied.reason == :requires_manual_mode
  end

  test "raw terminal can be explicitly allowed from any workspace, mode, and host" do
    Application.put_env(:dev_ide, :raw_terminal_everywhere, true)

    assert Boundary.raw_allowed?("ws-1", "local")
    assert Boundary.raw_allowed?("ws-1", "remote")
    assert :ok = Boundary.authorize_raw("ws-1", actor_id: "user-1", host_id: "remote")

    [allowed] = Ledger.recent_for("ws-1", 5)
    assert allowed.action == "run.session_attached"
    assert allowed.decision == :allow
    assert allowed.target_type == "session"
  end

  test "raw terminal stays gated when raw everywhere is explicitly disabled" do
    Application.put_env(:dev_ide, :raw_terminal_everywhere, false)

    refute Boundary.raw_allowed?("ws-1", "local")
    assert {:error, :requires_manual_mode} = Boundary.authorize_raw("ws-1", host_id: "local")

    Audit.clear()
    {:ok, _} = State.set_mode("ws-1", :manual)

    assert Boundary.raw_allowed?("ws-1", "local")
    assert :ok = Boundary.authorize_raw("ws-1", actor_id: "user-1", host_id: "local")
    assert {:error, :requires_local_host} = Boundary.authorize_raw("ws-1", host_id: "remote")

    [denied, allowed] = Ledger.recent_for("ws-1", 5)
    assert denied.action == "run.session_denied"
    assert denied.reason == :requires_local_host
    assert allowed.action == "run.session_attached"
    assert allowed.decision == :allow
    assert allowed.target_type == "session"
  end

  test "raw terminal does not allow local override without manual mode when re-tightened" do
    Application.put_env(:dev_ide, :raw_terminal_everywhere, false)
    Application.put_env(:dev_ide, :allow_local_raw_terminal, true)

    refute Boundary.raw_allowed?("ws-1", "local")
    assert {:error, :requires_manual_mode} = Boundary.authorize_raw("ws-1", host_id: "local")
  end

  defp seed_workspace(id, path) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: "alpha",
        user: "alice",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{
          "id" => id,
          "ports" => %{"tidewave" => 11_003},
          "domain_base" => "alice.workspaces.example.com"
        }
      })
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)
end
