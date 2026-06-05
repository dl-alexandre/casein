defmodule DevIDE.WorkspacesFolderTest do
  use ExUnit.Case, async: true

  alias DevIDE.Workspaces

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
    root = Application.get_env(:dev_ide, :workspaces_root, "/workspaces")
    inside = Path.join(root, "ws-test")
    assert Workspaces.path_under_allowed_roots?(inside)
  end
end
