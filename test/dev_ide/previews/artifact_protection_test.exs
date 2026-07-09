defmodule DevIDE.Previews.ArtifactProtectionTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Previews.ArtifactProtection
  alias DevIDE.Previews.Artifacts

  setup do
    prev_root = Application.get_env(:dev_ide, :preview_artifacts_root)
    prev_max = Application.get_env(:dev_ide, :preview_max_artifacts)
    root = Path.join(System.tmp_dir!(), "artifact-protection-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    Application.put_env(:dev_ide, :preview_artifacts_root, root)
    _ = ArtifactProtection.clear()

    on_exit(fn ->
      _ = ArtifactProtection.clear()
      File.rm_rf!(root)

      case prev_root do
        nil -> Application.delete_env(:dev_ide, :preview_artifacts_root)
        val -> Application.put_env(:dev_ide, :preview_artifacts_root, val)
      end

      case prev_max do
        nil -> Application.delete_env(:dev_ide, :preview_max_artifacts)
        val -> Application.put_env(:dev_ide, :preview_max_artifacts, val)
      end
    end)

    %{root: root}
  end

  test "protect/2 tracks basenames; protected/1 returns them; clear/0 resets" do
    assert ArtifactProtection.protected("ws-a") == MapSet.new()

    assert :ok = ArtifactProtection.protect("ws-a", "dir/shot.png")
    assert :ok = ArtifactProtection.protect("ws-a", "other.png")
    assert :ok = ArtifactProtection.protect("ws-b", "only-b.png")

    # Path.basename is applied so nested paths collapse to the filename.
    assert ArtifactProtection.protected("ws-a") == MapSet.new(["shot.png", "other.png"])
    assert ArtifactProtection.protected("ws-b") == MapSet.new(["only-b.png"])
    assert ArtifactProtection.protected("ws-missing") == MapSet.new()

    assert :ok = ArtifactProtection.clear()
    assert ArtifactProtection.protected("ws-a") == MapSet.new()
    assert ArtifactProtection.protected("ws-b") == MapSet.new()
  end

  test "protect/2 gates prune so displayed screenshots are not evicted", %{root: root} do
    Application.put_env(:dev_ide, :preview_max_artifacts, 1)

    Artifacts.store_png!("ws-protect", 1, "old")
    assert :ok = ArtifactProtection.protect("ws-protect", "1.png")
    Artifacts.store_png!("ws-protect", 2, "new")
    Artifacts.store_png!("ws-protect", 3, "newer")

    remaining = File.ls!(Path.join(root, "ws-protect")) |> Enum.sort()
    assert "1.png" in remaining
    assert "3.png" in remaining
    refute "2.png" in remaining
  end
end
