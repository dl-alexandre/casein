defmodule DevIDE.Previews.Storage.LocalDiskTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Previews.Storage.LocalDisk

  setup do
    root = Path.join(System.tmp_dir!(), "local-disk-test-#{System.unique_integer([:positive])}")
    prev_root = Application.get_env(:dev_ide, :preview_artifacts_root)
    Application.put_env(:dev_ide, :preview_artifacts_root, root)

    on_exit(fn ->
      case prev_root do
        nil -> Application.delete_env(:dev_ide, :preview_artifacts_root)
        value -> Application.put_env(:dev_ide, :preview_artifacts_root, value)
      end

      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "put writes a servable path and the file on disk", %{root: root} do
    assert {:ok, "/preview-artifacts/ws-1/7.png"} =
             LocalDisk.put("ws-1", "7", "png", {:bytes, "PNGDATA"})

    assert File.read!(Path.join([root, "ws-1", "7.png"])) == "PNGDATA"
  end

  describe "traversal rejection" do
    test "rejects a workspace_id that escapes the artifacts root", %{root: root} do
      assert {:error, :invalid_path} = LocalDisk.put("../evil", "1", "png", {:bytes, "x"})
      refute File.exists?(Path.join(Path.dirname(root), "evil"))
    end

    test "rejects an id containing a path separator", %{root: _root} do
      assert {:error, :invalid_path} =
               LocalDisk.put("ws-1", "../../etc/passwd", "png", {:bytes, "x"})
    end

    test "rejects a traversal sequence in the extension", %{root: _root} do
      assert {:error, :invalid_path} = LocalDisk.put("ws-1", "1", "../../escape", {:bytes, "x"})
    end

    test "rejects bare-dot components", %{root: _root} do
      assert {:error, :invalid_path} = LocalDisk.put("..", "1", "png", {:bytes, "x"})
      assert {:error, :invalid_path} = LocalDisk.put("ws-1", ".", "png", {:bytes, "x"})
    end
  end
end
