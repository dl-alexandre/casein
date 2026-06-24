defmodule DevideMob.HostBridgeTest do
  use ExUnit.Case, async: true

  alias DevideMob.HostBridge

  @tag :tmp_dir
  test "reads a text file under the configured root", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "note.txt"), "hello\nworld\n")

    assert {:ok, payload} = HostBridge.read_file(tmp_dir, "note.txt")
    assert payload.path == "note.txt"
    assert payload.content == "hello\nworld\n"
    assert payload.size == 12
    refute payload.truncated
  end

  @tag :tmp_dir
  test "rejects paths outside the configured root", %{tmp_dir: tmp_dir} do
    assert {:error, :outside_root} = HostBridge.read_file(tmp_dir, "../outside.txt")
  end

  @tag :tmp_dir
  test "rejects binary files", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "data.bin"), <<0, 1, 2, 3>>)

    assert {:error, :binary_file} = HostBridge.read_file(tmp_dir, "data.bin")
  end

  @tag :tmp_dir
  test "lists directories before files", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "mix.exs"), "Mix project")

    assert {:ok, %{entries: [dir, file]}} = HostBridge.list_dir(tmp_dir, ".")
    assert %{name: "lib", type: :directory} = dir
    assert %{name: "mix.exs", type: :regular} = file
  end
end
