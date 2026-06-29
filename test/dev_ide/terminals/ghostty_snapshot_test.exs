defmodule DevIDE.Terminals.GhosttySnapshotTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.GhosttySnapshot

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "ghostty-snap-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    prev = Application.get_env(:dev_ide, :ghostty_snapshot_dir)
    Application.put_env(:dev_ide, :ghostty_snapshot_dir, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:dev_ide, :ghostty_snapshot_dir, prev),
        else: Application.delete_env(:dev_ide, :ghostty_snapshot_dir)
    end)

    {:ok, term: start_supervised!({Ghostty.Terminal, cols: 40, rows: 6}), dir: tmp}
  end

  test "capture/2 writes html, plain, and vt snapshots under the configured dir", %{
    term: term,
    dir: dir
  } do
    :ok = Ghostty.Terminal.write(term, "hello snapshot\n")

    result = GhosttySnapshot.capture(term, "ws-test")

    assert result.base =~ "ghostty_snapshot_ws-test_"
    assert result.base |> Path.dirname() |> Path.expand() == Path.expand(dir)
    assert byte_size(result.preview) > 0
    assert String.contains?(result.preview, "hello")

    assert length(result.files) == 3

    for format <- ["html", "plain", "vt"] do
      file = Enum.find(result.files, &(&1["format"] == format))
      assert file
      assert File.exists?(file["path"])
      assert is_integer(file["bytes"])
      assert file["bytes"] > 0
    end
  end
end
