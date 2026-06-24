defmodule DevIDE.Previews.RecordingsTest do
  use ExUnit.Case, async: false

  alias DevIDE.Previews.Recordings

  setup do
    artifacts = Path.join(System.tmp_dir!(), "rec-art-#{System.unique_integer([:positive])}")
    recordings = Path.join(System.tmp_dir!(), "rec-tmp-#{System.unique_integer([:positive])}")
    prev_art = Application.get_env(:dev_ide, :preview_artifacts_root)
    prev_rec = Application.get_env(:dev_ide, :preview_recordings_root)
    prev_max = Application.get_env(:dev_ide, :preview_recording_max_bytes)

    Application.put_env(:dev_ide, :preview_artifacts_root, artifacts)
    Application.put_env(:dev_ide, :preview_recordings_root, recordings)

    on_exit(fn ->
      restore(:preview_artifacts_root, prev_art)
      restore(:preview_recordings_root, prev_rec)
      restore(:preview_recording_max_bytes, prev_max)
      File.rm_rf(artifacts)
      File.rm_rf(recordings)
    end)

    {:ok, artifacts: artifacts}
  end

  test "finalize concatenates chunks in seq order regardless of arrival order", %{
    artifacts: artifacts
  } do
    # Arrive out of order: 2, then 0, then 1.
    assert :ok = Recordings.append_chunk("ws-1", "rec-a", 2, "CCC")
    assert :ok = Recordings.append_chunk("ws-1", "rec-a", 0, "AAA")
    assert :ok = Recordings.append_chunk("ws-1", "rec-a", 1, "BBB")

    assert {:ok, "/preview-artifacts/ws-1/rec-a.webm"} = Recordings.finalize("ws-1", "rec-a")
    assert File.read!(Path.join([artifacts, "ws-1", "rec-a.webm"])) == "AAABBBCCC"
  end

  test "finalize cleans up the temp dir" do
    assert :ok = Recordings.append_chunk("ws-1", "rec-b", 0, "X")
    assert {:ok, _} = Recordings.finalize("ws-1", "rec-b")

    recordings = Application.get_env(:dev_ide, :preview_recordings_root)
    refute File.dir?(Path.join([recordings, "ws-1", "rec-b"]))
  end

  test "finalize with no chunks errors" do
    assert {:error, :no_chunks} = Recordings.finalize("ws-1", "missing")
  end

  test "rejects ids containing path traversal or illegal characters" do
    assert {:error, :invalid_id} = Recordings.append_chunk("ws-1", "../escape", 0, "X")
    assert {:error, :invalid_id} = Recordings.append_chunk("../ws", "rec", 0, "X")
    assert {:error, :invalid_id} = Recordings.finalize("ws-1", "bad/id")
  end

  test "enforces the configured max size across chunks" do
    Application.put_env(:dev_ide, :preview_recording_max_bytes, 4)

    assert :ok = Recordings.append_chunk("ws-2", "rec-c", 0, "AB")
    assert {:error, :recording_too_large} = Recordings.append_chunk("ws-2", "rec-c", 1, "CDE")
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
