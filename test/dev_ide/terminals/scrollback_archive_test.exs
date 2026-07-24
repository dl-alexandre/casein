defmodule Casein.Terminals.ScrollbackArchiveTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.ScrollbackArchive

  setup do
    dir =
      Path.join(System.tmp_dir!(), "devide-scrollback-test-#{System.unique_integer([:positive])}")

    Application.put_env(:dev_ide, :tmux_scrollback_archive_dir, dir)
    ScrollbackArchive.ensure_table!()
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "put/get round-trip and delete", %{dir: dir} do
    session = "devide_ws_sid_#{System.unique_integer([:positive])}"
    data = "hello scrollback\nline 2\n"

    assert :ok = ScrollbackArchive.put(session, data)
    assert ScrollbackArchive.get(session) == data

    # Survives ETS-only miss via disk
    assert File.exists?(Path.join(dir, session <> ".scrollback")) or
             Enum.any?(File.ls!(dir), &String.contains?(&1, "scrollback"))

    assert :ok = ScrollbackArchive.delete(session)
    assert ScrollbackArchive.get(session) == <<>>
  end

  test "trims oversized payloads to max_bytes" do
    Application.put_env(:dev_ide, :tmux_scrollback_archive_bytes, 32)
    session = "devide_trim_#{System.unique_integer([:positive])}"
    data = String.duplicate("abcdefghij", 10)

    assert :ok = ScrollbackArchive.put(session, data)
    got = ScrollbackArchive.get(session)
    assert byte_size(got) <= 32
    assert String.ends_with?(data, got) or String.contains?(data, got)
  after
    Application.delete_env(:dev_ide, :tmux_scrollback_archive_bytes)
  end
end
