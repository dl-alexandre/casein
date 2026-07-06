defmodule DevIDE.Previews.ArtifactsTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Previews.Artifacts

  setup do
    root = Path.join(System.tmp_dir!(), "artifacts-test-#{System.unique_integer([:positive])}")
    prev_root = Application.get_env(:dev_ide, :preview_artifacts_root)
    prev_max = Application.get_env(:dev_ide, :preview_max_artifacts)
    prev_diff_max = Application.get_env(:dev_ide, :preview_max_diff_artifacts)

    _ = DevIDE.Previews.ArtifactProtection.clear()
    Application.put_env(:dev_ide, :preview_artifacts_root, root)

    on_exit(fn ->
      _ = DevIDE.Previews.ArtifactProtection.clear()
      restore(:preview_artifacts_root, prev_root)
      restore(:preview_max_artifacts, prev_max)
      restore(:preview_max_diff_artifacts, prev_diff_max)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "store_png! writes a servable path and the file on disk", %{root: root} do
    path = Artifacts.store_png!("ws-1", 7, "PNGDATA")

    assert path == "/preview-artifacts/ws-1/7.png"
    assert File.read!(Path.join([root, "ws-1", "7.png"])) == "PNGDATA"
  end

  test "store_png! raises a clear error when the storage rejects the path" do
    assert_raise ArgumentError, ~r/could not store preview PNG/, fn ->
      Artifacts.store_png!("../escape", 7, "PNGDATA")
    end
  end

  test "store_png! prunes older artifacts down to the configured maximum", %{root: root} do
    Application.put_env(:dev_ide, :preview_max_artifacts, 3)

    # Write more than the cap; set explicit increasing mtimes so ordering is
    # deterministic without sleeping. Convert posix seconds to the Erlang
    # datetime tuple that File.touch!/2 expects (same pattern as janitor_test).
    base_time = 1_700_000_000

    for id <- 1..6 do
      Artifacts.store_png!("ws-2", id, "png-#{id}")
      path = Path.join([root, "ws-2", "#{id}.png"])
      erl_datetime = :calendar.gregorian_seconds_to_datetime(base_time + id + 62_167_219_200)
      File.touch!(path, erl_datetime)
    end

    remaining =
      [root, "ws-2"]
      |> Path.join()
      |> File.ls!()
      |> Enum.sort()

    # Only the 3 newest survive; the newest write is always kept.
    assert length(remaining) == 3
    assert "6.png" in remaining
    assert "5.png" in remaining
    assert "4.png" in remaining
    refute "1.png" in remaining
  end

  test "diff overlays use a separate prune budget from screenshots", %{root: root} do
    Application.put_env(:dev_ide, :preview_max_artifacts, 1)
    Application.put_env(:dev_ide, :preview_max_diff_artifacts, 2)

    base_time = 1_700_000_000

    touch = fn filename, offset ->
      path = Path.join([root, "ws-split", filename])
      erl_datetime = :calendar.gregorian_seconds_to_datetime(base_time + offset + 62_167_219_200)
      File.touch!(path, erl_datetime)
    end

    Artifacts.store_png!("ws-split", 1, "shot-1")
    touch.("1.png", 1)
    Artifacts.store_named_png!("ws-split", "9-diff", "diff-1")
    touch.("9-diff.png", 2)
    Artifacts.store_named_png!("ws-split", "10-diff", "diff-2")
    touch.("10-diff.png", 3)
    Artifacts.store_named_png!("ws-split", "11-diff", "diff-3")
    touch.("11-diff.png", 4)
    Artifacts.store_png!("ws-split", 2, "shot-2")
    touch.("2.png", 5)

    remaining =
      [root, "ws-split"]
      |> Path.join()
      |> File.ls!()
      |> Enum.sort()

    assert "2.png" in remaining
    refute "1.png" in remaining
    assert length(Enum.filter(remaining, &String.ends_with?(&1, "-diff.png"))) == 2
  end

  test "protected displayed artifacts are not pruned", %{root: root} do
    Application.put_env(:dev_ide, :preview_max_artifacts, 1)

    # Protect before the next store: with max_artifacts=1 each store prunes
    # everything older, so an unprotected 1.png would be legitimately gone by
    # the time 2.png lands (mirrors the real flow — an artifact is protected
    # while displayed, not retroactively).
    Artifacts.store_png!("ws-protect", 1, "old")
    :ok = DevIDE.Previews.ArtifactProtection.protect("ws-protect", "1.png")
    Artifacts.store_png!("ws-protect", 2, "new")
    Artifacts.store_png!("ws-protect", 3, "newer")

    remaining = File.ls!(Path.join(root, "ws-protect")) |> Enum.sort()
    assert "1.png" in remaining
    assert "3.png" in remaining
    refute "2.png" in remaining
  end

  test "a burst of same-second writes never prunes the just-written artifact", %{root: root} do
    Application.put_env(:dev_ide, :preview_max_artifacts, 1)

    # All three writes land within one mtime tick (posix-second granularity),
    # so pruning cannot order them by timestamp alone. The just-written file
    # must win the tie — put/4 returns its URL, which must not 404.
    Artifacts.store_png!("ws-burst", 1, "a")
    Artifacts.store_png!("ws-burst", 2, "b")
    Artifacts.store_png!("ws-burst", 3, "c")

    assert File.ls!(Path.join(root, "ws-burst")) == ["3.png"]
  end

  test "pruning is scoped per workspace", %{root: root} do
    Application.put_env(:dev_ide, :preview_max_artifacts, 1)

    Artifacts.store_png!("ws-a", 1, "a")
    Artifacts.store_png!("ws-b", 1, "b")

    assert File.exists?(Path.join([root, "ws-a", "1.png"]))
    assert File.exists?(Path.join([root, "ws-b", "1.png"]))
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
