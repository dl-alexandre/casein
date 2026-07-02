defmodule DevIDE.WorkspaceSource.ManagerTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.WorkspaceSource.Manager, as: WorkspaceSource
  alias DevIDE.Workspace

  setup do
    keys = [:on_devbox, :devbox_exec_service, :devbox_exec_workdir, :remote_ssh_host]
    prev = Map.new(keys, &{&1, Application.get_env(:dev_ide, &1)})

    on_exit(fn -> Enum.each(prev, fn {k, v} -> restore(k, v) end) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  describe "on_host?/0 and exec_service/0" do
    test "on_host? reflects the :on_devbox config flag" do
      Application.put_env(:dev_ide, :on_devbox, true)
      assert WorkspaceSource.on_host?()

      Application.put_env(:dev_ide, :on_devbox, false)
      refute WorkspaceSource.on_host?()
    end

    test "exec_service defaults to onebackend-v3 and is overridable" do
      Application.delete_env(:dev_ide, :devbox_exec_service)
      assert WorkspaceSource.exec_service() == "onebackend-v3"

      Application.put_env(:dev_ide, :devbox_exec_service, "custom-svc")
      assert WorkspaceSource.exec_service() == "custom-svc"
    end

    test "exec_workdir defaults to /app and is overridable" do
      Application.delete_env(:dev_ide, :devbox_exec_workdir)
      assert WorkspaceSource.exec_workdir() == "/app"

      Application.put_env(:dev_ide, :devbox_exec_workdir, "/workspace")
      assert WorkspaceSource.exec_workdir() == "/workspace"
    end
  end

  describe "safe_host_loc/1" do
    test "on-host mode returns {:local, path} for paths under /data/workspaces" do
      Application.put_env(:dev_ide, :on_devbox, true)

      ws = %Workspace{id: "x", name: "n", path: "/data/workspaces/alice-feature"}

      assert {:ok, {:local, "/data/workspaces/alice-feature"}} =
               WorkspaceSource.safe_host_loc(ws)
    end

    test "on-host mode rejects paths outside /data/workspaces" do
      Application.put_env(:dev_ide, :on_devbox, true)

      ws = %Workspace{id: "x", name: "n", path: "/etc/passwd"}
      assert {:error, :outside_root} = WorkspaceSource.safe_host_loc(ws)
    end

    test "on-host mode takes precedence over :remote_ssh_host" do
      Application.put_env(:dev_ide, :on_devbox, true)
      Application.put_env(:dev_ide, :remote_ssh_host, "boxname")

      ws = %Workspace{id: "x", name: "n", path: "/data/workspaces/bob"}
      assert {:ok, {:local, "/data/workspaces/bob"}} = WorkspaceSource.safe_host_loc(ws)
    end

    test "with :remote_ssh_host set (not on-host) returns a remote loc" do
      Application.put_env(:dev_ide, :on_devbox, false)
      Application.put_env(:dev_ide, :remote_ssh_host, "boxname")

      ws = %Workspace{id: "x", name: "n", path: "/data/workspaces/bob"}

      assert {:ok, {:remote, "boxname", "/data/workspaces/bob"}} =
               WorkspaceSource.safe_host_loc(ws)
    end
  end

  describe "prepare_local_argv/1 and local_tmux_pane_shell/0" do
    test "on-host mode wraps argv with docker compose exec" do
      Application.put_env(:dev_ide, :on_devbox, true)
      Application.put_env(:dev_ide, :devbox_exec_service, "svc")

      argv = WorkspaceSource.prepare_local_argv(["mix", "test"])

      assert ["compose", "exec", "-T", "--workdir", "/app", "svc", "mix", "test"] =
               Enum.drop(argv, 1)
    end

    test "on-host mode pins compose project and container workdir when cwd is supplied" do
      Application.put_env(:dev_ide, :on_devbox, true)
      Application.put_env(:dev_ide, :devbox_exec_service, "svc")

      argv =
        WorkspaceSource.prepare_local_argv(["tmux", "new-session"],
          tty: true,
          cwd: "/data/workspaces/alice-feature",
          normal_cwd: "/data/workspaces/alice-feature"
        )

      assert ["compose", "--project-directory", "/data/workspaces/alice-feature", "exec"] =
               Enum.drop(argv, 1) |> Enum.take(4)

      assert Enum.drop(argv, 5) |> Enum.take(3) == ["--workdir", "/app", "svc"]
      assert Enum.at(argv, 8) == "sh"
      assert Enum.at(argv, 9) == "-lc"
      assert Enum.at(argv, 10) =~ "ln -s '/app' '/data/workspaces/alice-feature'"
      assert Enum.at(argv, 10) =~ "cd '/data/workspaces/alice-feature'"
      assert Enum.at(argv, 10) =~ "exec 'tmux' 'new-session'"
    end

    test "off-host mode is identity" do
      Application.put_env(:dev_ide, :on_devbox, false)
      assert WorkspaceSource.prepare_local_argv(["mix", "test"]) == ["mix", "test"]
      assert WorkspaceSource.local_exec_cwd("/tmp/ws") == "/tmp/ws"
    end

    test "on-host mode preserves normal workspace cwd for wrapped commands" do
      Application.put_env(:dev_ide, :on_devbox, true)

      assert WorkspaceSource.local_exec_cwd("/data/workspaces/alice-feature") ==
               "/data/workspaces/alice-feature"
    end

    test "on-host tmux pane shell uses docker compose exec" do
      Application.put_env(:dev_ide, :on_devbox, true)
      Application.put_env(:dev_ide, :devbox_exec_service, "svc")

      assert WorkspaceSource.local_tmux_pane_shell() ==
               "docker compose exec --workdir '/app' svc bash -l"
    end

    test "cwd-aware tmux pane shell falls back to host shell when compose is unavailable" do
      Application.put_env(:dev_ide, :on_devbox, true)
      Application.put_env(:dev_ide, :devbox_exec_service, "svc")

      missing_project =
        Path.join(System.tmp_dir!(), "missing-compose-#{System.unique_integer([:positive])}")

      assert WorkspaceSource.local_tmux_pane_shell(missing_project) == nil
    end

    test "off-host tmux pane shell is nil (default shell)" do
      Application.put_env(:dev_ide, :on_devbox, false)
      assert WorkspaceSource.local_tmux_pane_shell() == nil
    end
  end

  describe "detect_capabilities/2" do
    test "advertises preview MCP alongside manager capabilities" do
      ws = %Workspace{
        id: "x",
        name: "n",
        path: nil,
        metadata: %{
          type: :v3,
          domain_base: "alice.workspaces.example.com",
          ports: %{"tidewave" => 11_003}
        }
      }

      caps = WorkspaceSource.detect_capabilities(ws, nil)

      assert Enum.find(caps, &(&1.kind == :tidewave)).status == :detected

      preview_mcp = Enum.find(caps, &(&1.kind == :preview_mcp))
      assert preview_mcp.status == :detected
      assert preview_mcp.url =~ "/api/preview/mcp"
      assert "preview_close" in preview_mcp.details.tools
    end
  end
end
