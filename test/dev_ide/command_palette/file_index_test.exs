defmodule DevIDE.CommandPalette.FileIndexTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.CommandPalette.FileIndex

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "file-index-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join([root, "lib", "cached.ex"]), "")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "list/1 returns a stable listing", %{root: root} do
    assert "lib/cached.ex" in FileIndex.list(root)
  end

  test "list/1 serves cached results until invalidate/1", %{root: root} do
    assert "lib/cached.ex" in FileIndex.list(root)

    File.write!(Path.join([root, "lib", "new_after_cache.ex"]), "")
    refute "lib/new_after_cache.ex" in FileIndex.list(root)

    FileIndex.invalidate(root)
    assert "lib/new_after_cache.ex" in FileIndex.list(root)
  end
end
