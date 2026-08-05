defmodule Casein.CommandPalette.FileIndexCacheTest do
  @moduledoc """
  The palette re-queries on every keystroke and each walk is a `File.ls/1` per
  directory plus a `File.lstat/1` per entry (up to 5_000 files), run
  synchronously on the LiveView process. Without memoization a 7-character query
  meant 7 full walks; combined with the input debounce this collapses a typing
  burst onto one.
  """
  use ExUnit.Case, async: false

  alias Casein.CommandPalette.FileIndex

  setup do
    root = Path.join(System.tmp_dir!(), "palette-index-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.txt"), "a")
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root}
  end

  test "repeated calls within the TTL do not re-walk the filesystem", %{root: root} do
    assert FileIndex.list(root) == ["a.txt"]

    # A file created after the first walk must NOT appear while the entry is
    # still warm — that is the observable proof the second call was served from
    # cache rather than re-walking.
    File.write!(Path.join(root, "b.txt"), "b")

    assert FileIndex.list(root) == ["a.txt"]
  end

  test "the cache expires so new files still surface", %{root: root} do
    assert FileIndex.list(root) == ["a.txt"]
    File.write!(Path.join(root, "b.txt"), "b")

    # Expire the entry rather than sleeping out the real TTL. Note the deadline
    # must come from the same monotonic clock the cache uses — BEAM monotonic
    # time is commonly negative, so a literal 0 would still be "in the future".
    expired_at = System.monotonic_time(:millisecond) - 1
    :ets.insert(:casein_palette_file_index_cache, {Path.expand(root), ["a.txt"], expired_at})

    assert Enum.sort(FileIndex.list(root)) == ["a.txt", "b.txt"]
  end

  test "distinct roots are cached independently", %{root: root} do
    other = Path.join(System.tmp_dir!(), "palette-index-#{System.unique_integer([:positive])}")
    File.mkdir_p!(other)
    File.write!(Path.join(other, "z.txt"), "z")
    on_exit(fn -> File.rm_rf(other) end)

    assert FileIndex.list(root) == ["a.txt"]
    assert FileIndex.list(other) == ["z.txt"]
  end

  test "a non-directory root still returns an empty list" do
    assert FileIndex.list("/definitely/not/a/real/path") == []
    assert FileIndex.list(nil) == []
  end
end
