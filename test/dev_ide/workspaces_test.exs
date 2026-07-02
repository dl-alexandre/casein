defmodule DevIDE.WorkspacesTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter
  alias DevIDE.Workspace

  setup do
    keys = [:workspaces_root, :workspaces_roots, :workspace_source, :workspace_state_adapter]
    prev = Map.new(keys, &{&1, Application.get_env(:dev_ide, &1)})
    Application.put_env(:dev_ide, :workspace_state_adapter, MemoryAdapter)
    MemoryAdapter.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      Enum.each(prev, fn {k, v} -> restore(k, v) end)
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

  test "viewer_can_access_workspace? allows admins and owners only" do
    ws = %Workspace{id: "x", name: "n", user: "alice"}
    alice = %{id: "alice", email: "alice@example.com"}
    bob = %{id: "bob", email: "bob@example.com"}
    admin = %{id: "ops", email: "ops@example.com", role: :admin}

    assert Workspaces.viewer_can_access_workspace?(ws, alice)
    refute Workspaces.viewer_can_access_workspace?(ws, bob)
    assert Workspaces.viewer_can_access_workspace?(ws, admin)
  end

  test "viewer_owns_workspace? matches id, username, or email local part" do
    ws = %Workspace{id: "x", name: "alice-app", user: "alice"}

    assert Workspaces.viewer_owns_workspace?(ws, %{id: "alice", email: "alice@example.com"})
    refute Workspaces.viewer_owns_workspace?(ws, %{id: "bob", email: "bob@example.com"})
  end

  test "viewer_terminal_owner? is true for admins even when they do not own the workspace" do
    ws = %Workspace{id: "x", name: "alice-app", user: "alice"}

    assert Workspaces.viewer_terminal_owner?(ws, %{id: "boss", role: :admin})
    refute Workspaces.viewer_terminal_owner?(ws, %{id: "bob", role: :owner})
  end

  test "forward_auth_email derives owner username plus configured domain" do
    Application.put_env(:dev_ide, :forward_auth_email_domain, "milcgroup.com")

    ws = %Workspace{id: "x", name: "alice-app", user: "Alice"}

    assert Workspaces.forward_auth_email(ws) == "alice@milcgroup.com"

    assert Workspaces.forward_auth_headers(ws) == %{
             "X-Auth-Request-Email" => "alice@milcgroup.com"
           }
  end

  test "extra roots from :workspaces_roots are honored" do
    Application.put_env(:dev_ide, :workspaces_root, "/workspaces")
    Application.put_env(:dev_ide, :workspaces_roots, ["/srv/other"])

    ws = %Workspace{id: "x", name: "n", path: "/srv/other/bob"}
    assert {:ok, "/srv/other/bob"} = Workspaces.safe_host_path(ws)
  end

  test "list syncs local source workspaces into state" do
    root = tmp_dir("devide-workspaces-source")
    alpha_path = Path.join(root, "alpha")
    File.mkdir_p!(alpha_path)

    Application.put_env(:dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local)
    Application.put_env(:dev_ide, :workspaces_root, root)

    assert {:ok, [%Workspace{id: "alpha", path: ^alpha_path}]} = Workspaces.list()

    assert {:ok, record} = State.get("alpha")
    assert record.external_id == "alpha"
    assert record.name == "alpha"
    assert record.host_path == alpha_path
    assert record.status == "running"
  end

  test "attached folder ids round-trip through get and sync state" do
    root = tmp_dir("devide-attached-root")
    folder = Path.join(root, "attached")
    File.mkdir_p!(folder)

    Application.put_env(:dev_ide, :workspaces_root, root)

    assert {:ok, attached} = Workspaces.attach_folder(folder)
    assert String.starts_with?(attached.id, "folder:")
    assert Workspaces.decode_folder_id(attached.id) == folder
    assert {:ok, {:local, ^folder}} = Workspaces.safe_host_loc(attached)

    assert {:ok, fetched} = Workspaces.get(attached.id)
    assert fetched.path == folder

    assert {:ok, record} = State.get(attached.id)
    assert record.external_id == attached.id
    assert record.manager_payload == %{attached_folder: true}
  end

  test "path_under_allowed_roots? rejects sibling prefixes" do
    root = tmp_dir("devide-root")
    Application.put_env(:dev_ide, :workspaces_root, root)

    assert Workspaces.path_under_allowed_roots?(root)
    assert Workspaces.path_under_allowed_roots?(Path.join(root, "child"))
    refute Workspaces.path_under_allowed_roots?(root <> "-sibling/child")
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

  describe "attached folder owner derivation" do
    test "attach_folder derives the owner from the /<root>/<user>/<project> segment" do
      Application.put_env(:dev_ide, :forward_auth_email_domain, "milcgroup.com")
      root = tmp_dir("devide-owner-root")
      Application.put_env(:dev_ide, :workspaces_root, root)
      project = Path.join([root, "alice", "proj"])
      File.mkdir_p!(project)

      assert {:ok, ws} = Workspaces.attach_folder(project)
      assert %Workspace{user: "alice", metadata: %{attached_folder: true}} = ws

      assert Workspaces.forward_auth_email(ws) == "alice@milcgroup.com"

      assert Workspaces.forward_auth_headers(ws) == %{
               "X-Auth-Request-Email" => "alice@milcgroup.com"
             }
    end

    test "attach_folder leaves owner nil when the path is the root itself" do
      Application.put_env(:dev_ide, :forward_auth_email_domain, "milcgroup.com")
      root = tmp_dir("devide-owner-root-only")
      Application.put_env(:dev_ide, :workspaces_root, root)

      assert {:ok, ws} = Workspaces.attach_folder(root)
      assert %Workspace{user: nil, metadata: %{attached_folder: true}} = ws
      assert Workspaces.forward_auth_email(ws) == nil
      assert Workspaces.forward_auth_headers(ws) == nil
    end
  end

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
