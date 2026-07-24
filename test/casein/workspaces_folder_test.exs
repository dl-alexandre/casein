defmodule Casein.WorkspacesFolderTest do
  use Casein.TestCase, async: false

  alias Casein.Workspaces

  setup do
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_roots = Application.get_env(:casein, :workspaces_roots)
    prev_home_workspace_path = Application.get_env(:casein, :home_workspace_path)

    on_exit(fn ->
      restore(:workspaces_root, prev_root)
      restore(:workspaces_roots, prev_roots)
      restore(:home_workspace_path, prev_home_workspace_path)
    end)

    :ok
  end

  test "attach_folder/1 rejects paths outside allowed roots" do
    outside = Path.join(System.tmp_dir!(), "devide-outside-#{System.unique_integer()}")
    File.mkdir_p!(outside)

    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, :outside_allowed_roots} = Workspaces.attach_folder(outside)
  end

  test "get/2 rejects folder ids outside allowed roots" do
    outside = Path.join(System.tmp_dir!(), "devide-folder-get-#{System.unique_integer()}")
    File.mkdir_p!(outside)

    on_exit(fn -> File.rm_rf(outside) end)

    id = "folder:" <> Base.url_encode64(outside, padding: false)
    assert {:error, :outside_allowed_roots} = Workspaces.get(id, nil)
  end

  test "path_under_allowed_roots?/1 accepts paths under workspaces_root" do
    root = Application.get_env(:casein, :workspaces_root) || "/workspaces"
    inside = Path.join(root, "ws-test")
    assert Workspaces.path_under_allowed_roots?(inside)
  end

  test "path_under_allowed_roots?/1 accepts the configured home workspace path" do
    home = Path.join(System.tmp_dir!(), "devide-folder-home-#{System.unique_integer()}")
    File.mkdir_p!(home)
    Application.put_env(:casein, :home_workspace_path, home)

    on_exit(fn -> File.rm_rf(home) end)

    assert Workspaces.path_under_allowed_roots?(home)
    assert Workspaces.path_under_allowed_roots?(Path.join(home, "nested"))
    assert home in Workspaces.allowed_roots()
  end

  test "list_attachable_folders/1 lists child directories under allowed roots" do
    root = Path.join(System.tmp_dir!(), "devide-folder-list-#{System.unique_integer()}")
    child = Path.join(root, "child")
    nested = Path.join(child, "nested")
    file = Path.join(root, "not-a-folder.txt")
    File.mkdir_p!(nested)
    File.write!(file, "nope")

    Application.put_env(:casein, :workspaces_root, root)
    Application.put_env(:casein, :workspaces_roots, [])

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, listing} = Workspaces.list_attachable_folders(nil)
    assert listing.path == root
    assert listing.parent == nil
    assert listing.roots == [root]
    assert listing.entries == [%{name: "child", path: child}]

    assert {:ok, nested_listing} = Workspaces.list_attachable_folders(child)
    assert nested_listing.path == child
    assert nested_listing.parent == root
    assert nested_listing.entries == [%{name: "nested", path: nested}]
  end

  test "list_attachable_folders/1 rejects paths outside allowed roots" do
    root = Path.join(System.tmp_dir!(), "devide-folder-root-#{System.unique_integer()}")
    outside = Path.join(System.tmp_dir!(), "devide-folder-outside-#{System.unique_integer()}")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)

    Application.put_env(:casein, :workspaces_root, root)
    Application.put_env(:casein, :workspaces_roots, [])

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    assert {:error, :outside_allowed_roots} = Workspaces.list_attachable_folders(outside)
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
