defmodule DevIDE.Workspaces.AliasesTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.Workspaces.Aliases

  test "folder_id_for_path/1 encodes absolute paths" do
    assert Aliases.folder_id_for_path("/data/workspaces/dalexandre/dev_ide") ==
             "folder:L2RhdGEvd29ya3NwYWNlcy9kYWxleGFuZHJlL2Rldl9pZGU"
  end

  test "linked?/2 matches folder ids for the same path" do
    left = Aliases.folder_id_for_path("/tmp/dev_ide_aliases")
    right = Aliases.folder_id_for_path("/tmp/dev_ide_aliases")

    assert Aliases.linked?(left, right)
    refute Aliases.linked?(left, Aliases.folder_id_for_path("/tmp/other"))
  end

  test "viewer_ids/1 always includes the folder id for folder workspaces" do
    path = "/tmp/dev_ide_aliases_viewer"
    folder_id = Aliases.folder_id_for_path(path)

    assert folder_id in Aliases.viewer_ids(folder_id)
  end

  test "viewer_ids/1 returns the input ID when no linked workspaces exist" do
    ids = Aliases.viewer_ids("some-unknown-workspace-id")
    assert "some-unknown-workspace-id" in ids
  end
end
