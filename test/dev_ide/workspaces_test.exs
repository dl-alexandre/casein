defmodule DevIDE.WorkspacesTest do
  use ExUnit.Case, async: false

  alias DevIDE.Workspaces
  alias DevIDE.Workspace

  setup do
    keys = [:workspaces_root, :workspaces_roots, :workspace_source]
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
    Application.put_env(:dev_ide, :workspaces_roots, ["/srv/other"])

    ws = %Workspace{id: "x", name: "n", path: "/srv/other/bob"}
    assert {:ok, "/srv/other/bob"} = Workspaces.safe_host_path(ws)
  end

  describe "safe_host_loc/1 — Local source" do
    setup do
      Application.put_env(:dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local)
      Application.put_env(:dev_ide, :workspaces_root, "/workspaces")
      :ok
    end

    test "returns {:local, path} for paths under the configured root" do
      assert {:ok, {:local, "/workspaces/carol"}} =
               Workspaces.safe_host_loc(%Workspace{id: "x", name: "n", path: "/workspaces/carol"})
    end

    test "rejects paths outside the configured root" do
      assert {:error, :outside_root} =
               Workspaces.safe_host_loc(%Workspace{id: "x", name: "n", path: "/etc"})
    end
  end

  describe "owns?/2" do
    test "true when the workspace's user matches the username" do
      assert Workspaces.owns?(%Workspace{id: "x", name: "n", user: "rgomez"}, "rgomez")
      assert Workspaces.owns?(%{user: "rgomez"}, "rgomez")
    end

    test "false on mismatch" do
      refute Workspaces.owns?(%Workspace{id: "x", name: "n", user: "rgomez"}, "jhanf")
    end

    test "false when ownership data is missing" do
      refute Workspaces.owns?(%Workspace{id: "x", name: "n", user: nil}, "rgomez")
      refute Workspaces.owns?(%Workspace{id: "x", name: "n", user: "rgomez"}, nil)
      refute Workspaces.owns?(%{}, "rgomez")
    end
  end
end
