defmodule DevIDE.Files.VersionTest do
  use ExUnit.Case, async: true
  alias DevIDE.Files.Version

  test "compute is deterministic for identical content + stat" do
    stat = %File.Stat{size: 5, mtime: {{2026, 5, 8}, {1, 2, 3}}}
    assert Version.compute("hello", stat) == Version.compute("hello", stat)
  end

  test "compute differs when content changes" do
    stat = %File.Stat{size: 5, mtime: {{2026, 5, 8}, {1, 2, 3}}}
    refute Version.compute("hello", stat) == Version.compute("world", stat)
  end

  test "compute differs when mtime changes" do
    s1 = %File.Stat{size: 5, mtime: {{2026, 5, 8}, {1, 2, 3}}}
    s2 = %File.Stat{size: 5, mtime: {{2026, 5, 8}, {1, 2, 4}}}
    refute Version.compute("hello", s1) == Version.compute("hello", s2)
  end

  test "compute_path reads disk and produces a token" do
    path = Path.join(System.tmp_dir!(), "vt-#{System.unique_integer([:positive])}")
    File.write!(path, "abc")
    assert {:ok, token} = Version.compute_path(path)
    assert is_binary(token) and byte_size(token) > 0
    File.rm!(path)
  end
end
