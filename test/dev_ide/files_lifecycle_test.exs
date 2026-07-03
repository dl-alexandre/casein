defmodule DevIDE.FilesLifecycleTest do
  use DevIDE.TestCase, async: true
  alias DevIDE.Files

  setup do
    root = Path.join(System.tmp_dir!(), "fl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "create_file then delete", %{root: root} do
    assert {:ok, v} = Files.create_file(root, "new.txt")
    assert is_binary(v)
    assert File.exists?(Path.join(root, "new.txt"))
    assert :ok = Files.delete(root, "new.txt")
    refute File.exists?(Path.join(root, "new.txt"))
  end

  test "create_file refuses existing path", %{root: root} do
    {:ok, _} = Files.create_file(root, "x.txt")
    assert {:error, :exists} = Files.create_file(root, "x.txt")
  end

  test "create_file refuses traversal", %{root: root} do
    assert {:error, :outside_root} = Files.create_file(root, "../escape")
  end

  test "create_dir + non-empty rmdir refused", %{root: root} do
    :ok = Files.create_dir(root, "sub")
    {:ok, _} = Files.create_file(root, "sub/inside.txt")
    assert {:error, :not_empty} = Files.delete(root, "sub")
    :ok = Files.delete(root, "sub/inside.txt")
    assert :ok = Files.delete(root, "sub")
  end

  test "rename within root", %{root: root} do
    {:ok, _} = Files.create_file(root, "a.txt")
    assert :ok = Files.rename(root, "a.txt", "b.txt")
    assert File.exists?(Path.join(root, "b.txt"))
    refute File.exists?(Path.join(root, "a.txt"))
  end

  test "rename refuses traversal on either side", %{root: root} do
    {:ok, _} = Files.create_file(root, "a.txt")
    assert {:error, :outside_root} = Files.rename(root, "a.txt", "../leak.txt")
    assert {:error, :outside_root} = Files.rename(root, "../leak.txt", "a.txt")
  end

  test "rename refuses overwriting existing target", %{root: root} do
    {:ok, _} = Files.create_file(root, "a.txt")
    {:ok, _} = Files.create_file(root, "b.txt")
    assert {:error, :exists} = Files.rename(root, "a.txt", "b.txt")
  end

  test "delete refuses traversal", %{root: root} do
    assert {:error, :outside_root} = Files.delete(root, "../escape")
  end

  test "copy duplicates a file", %{root: root} do
    {:ok, _} = Files.create_file(root, "a.txt")
    File.write!(Path.join(root, "a.txt"), "hello")
    assert :ok = Files.copy(root, "a.txt", "a copy.txt")
    assert File.read!(Path.join(root, "a copy.txt")) == "hello"
    assert File.exists?(Path.join(root, "a.txt"))
  end

  test "copy duplicates a directory recursively", %{root: root} do
    :ok = Files.create_dir(root, "sub")
    {:ok, _} = Files.create_file(root, "sub/inside.txt")
    assert :ok = Files.copy(root, "sub", "sub2")
    assert File.exists?(Path.join(root, "sub2/inside.txt"))
  end

  test "copy refuses missing source", %{root: root} do
    assert {:error, :not_found} = Files.copy(root, "nope.txt", "dst.txt")
  end

  test "copy refuses existing destination", %{root: root} do
    {:ok, _} = Files.create_file(root, "a.txt")
    {:ok, _} = Files.create_file(root, "b.txt")
    assert {:error, :exists} = Files.copy(root, "a.txt", "b.txt")
  end

  test "copy refuses traversal on either side", %{root: root} do
    {:ok, _} = Files.create_file(root, "a.txt")
    assert {:error, :outside_root} = Files.copy(root, "a.txt", "../leak.txt")
    assert {:error, :outside_root} = Files.copy(root, "../leak.txt", "a.txt")
  end
end
