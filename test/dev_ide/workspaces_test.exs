defmodule DevIDE.WorkspacesTest do
  use ExUnit.Case, async: false

  alias DevIDE.Workspaces
  alias DevIDE.Devbox.Workspace

  setup do
    keys = [
      :workspaces_root,
      :workspaces_roots,
      :on_devbox,
      :devbox_exec_service,
      :remote_ssh_host
    ]

    prev = Map.new(keys, &{&1, Application.get_env(:dev_ide, &1)})

    on_exit(fn -> Enum.each(prev, fn {k, v} -> restore(k, v) end) end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  test "safe_host_path accepts a path under the configured root" do
    Application.put_env(:dev_ide, :workspaces_root, "/workspaces")

    ws = %Workspace{id: "x", name: "n", path: "/workspaces/alice"}
    assert {:ok, "/workspaces/alice"} = Workspaces.safe_host_path(ws)
  end

  test "safe_host_path rejects a path outside the allowed roots" do
    Application.put_env(:dev_ide, :workspaces_root, "/workspaces")

    ws = %Workspace{id: "x", name: "n", path: "/etc/passwd"}
    assert {:error, :outside_root} = Workspaces.safe_host_path(ws)
  end

  test "safe_host_path rejects path traversal" do
    Application.put_env(:dev_ide, :workspaces_root, "/workspaces")

    ws = %Workspace{id: "x", name: "n", path: "/workspaces/../etc"}
    assert {:error, :outside_root} = Workspaces.safe_host_path(ws)
  end

  test "safe_host_path returns :missing_path when path is nil or empty" do
    assert {:error, :missing_path} =
             Workspaces.safe_host_path(%Workspace{id: "x", name: "n", path: nil})

    assert {:error, :missing_path} =
             Workspaces.safe_host_path(%Workspace{id: "x", name: "n", path: ""})
  end

  test "extra roots from :workspaces_roots are honored" do
    Application.put_env(:dev_ide, :workspaces_root, "/workspaces")
    Application.put_env(:dev_ide, :workspaces_roots, ["/srv/devbox"])

    ws = %Workspace{id: "x", name: "n", path: "/srv/devbox/bob"}
    assert {:ok, "/srv/devbox/bob"} = Workspaces.safe_host_path(ws)
  end

  describe "on_devbox?/0 and devbox_exec_service/0" do
    test "on_devbox? reflects the :on_devbox config flag" do
      Application.put_env(:dev_ide, :on_devbox, true)
      assert Workspaces.on_devbox?()

      Application.put_env(:dev_ide, :on_devbox, false)
      refute Workspaces.on_devbox?()
    end

    test "devbox_exec_service defaults to onebackend-v3 and is overridable" do
      Application.delete_env(:dev_ide, :devbox_exec_service)
      assert Workspaces.devbox_exec_service() == "onebackend-v3"

      Application.put_env(:dev_ide, :devbox_exec_service, "custom-svc")
      assert Workspaces.devbox_exec_service() == "custom-svc"
    end
  end

  describe "safe_host_loc/1" do
    test "on-devbox mode returns {:local, path} for paths under /data/workspaces" do
      Application.put_env(:dev_ide, :on_devbox, true)

      ws = %Workspace{id: "x", name: "n", path: "/data/workspaces/alice-feature"}
      assert {:ok, {:local, "/data/workspaces/alice-feature"}} = Workspaces.safe_host_loc(ws)
    end

    test "on-devbox mode rejects paths outside /data/workspaces" do
      Application.put_env(:dev_ide, :on_devbox, true)

      ws = %Workspace{id: "x", name: "n", path: "/etc/passwd"}
      assert {:error, :outside_root} = Workspaces.safe_host_loc(ws)
    end

    test "on-devbox mode takes precedence over :remote_ssh_host" do
      Application.put_env(:dev_ide, :on_devbox, true)
      Application.put_env(:dev_ide, :remote_ssh_host, "devbox")

      ws = %Workspace{id: "x", name: "n", path: "/data/workspaces/bob"}
      assert {:ok, {:local, "/data/workspaces/bob"}} = Workspaces.safe_host_loc(ws)
    end

    test "with :remote_ssh_host set (not on-devbox) returns a remote loc" do
      Application.put_env(:dev_ide, :on_devbox, false)
      Application.put_env(:dev_ide, :remote_ssh_host, "devbox")

      ws = %Workspace{id: "x", name: "n", path: "/data/workspaces/bob"}
      assert {:ok, {:remote, "devbox", "/data/workspaces/bob"}} = Workspaces.safe_host_loc(ws)
    end

    test "plain local mode checks the configured allowed roots" do
      Application.put_env(:dev_ide, :on_devbox, false)
      Application.delete_env(:dev_ide, :remote_ssh_host)
      Application.put_env(:dev_ide, :workspaces_root, "/workspaces")

      assert {:ok, {:local, "/workspaces/carol"}} =
               Workspaces.safe_host_loc(%Workspace{id: "x", name: "n", path: "/workspaces/carol"})

      assert {:error, :outside_root} =
               Workspaces.safe_host_loc(%Workspace{id: "x", name: "n", path: "/etc"})
    end
  end
end
