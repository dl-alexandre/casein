defmodule DevIDE.WorkspacesTest do
  use ExUnit.Case, async: false

  alias DevIDE.Workspaces
  alias DevIDE.Devbox.Workspace

  setup do
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_extra = Application.get_env(:dev_ide, :workspaces_roots)

    on_exit(fn ->
      restore(:workspaces_root, prev_root)
      restore(:workspaces_roots, prev_extra)
    end)

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
end
