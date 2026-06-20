defmodule DevIDE.Previews.ArtifactsTest do
  use ExUnit.Case, async: false

  alias DevIDE.Previews.Artifacts

  setup do
    root = Path.join(System.tmp_dir!(), "artifacts-test-#{System.unique_integer([:positive])}")
    prev_root = Application.get_env(:dev_ide, :preview_artifacts_root)
    prev_max = Application.get_env(:dev_ide, :preview_max_artifacts)

    Application.put_env(:dev_ide, :preview_artifacts_root, root)

    on_exit(fn ->
      restore(:preview_artifacts_root, prev_root)
      restore(:preview_max_artifacts, prev_max)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "store_png! writes a servable path and the file on disk", %{root: root} do
    path = Artifacts.store_png!("ws-1", 7, "PNGDATA")

    assert path == "/preview-artifacts/ws-1/7.png"
    assert File.read!(Path.join([root, "ws-1", "7.png"])) == "PNGDATA"
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

  test "pruning is scoped per workspace", %{root: root} do
    Application.put_env(:dev_ide, :preview_max_artifacts, 1)

    Artifacts.store_png!("ws-a", 1, "a")
    Artifacts.store_png!("ws-b", 1, "b")

    assert File.exists?(Path.join([root, "ws-a", "1.png"]))
    assert File.exists?(Path.join([root, "ws-b", "1.png"]))
  end

  defp restore(_key, nil), do: :ok
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
