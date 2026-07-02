defmodule DevIDE.FilesWriteTest do
  use DevIDE.TestCase, async: true
  alias DevIDE.Files

  setup do
    root = Path.join(System.tmp_dir!(), "fw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "hello.txt"), "alpha\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "write_text succeeds with current version", %{root: root} do
    {:ok, %{version: v}} = Files.read_text(root, "hello.txt")
    assert {:ok, %{version: v2}} = Files.write_text(root, "hello.txt", "beta\n", v)
    assert v2 != v
    assert File.read!(Path.join(root, "hello.txt")) == "beta\n"
  end

  test "write_text returns :conflict when version is stale", %{root: root} do
    {:ok, %{version: v}} = Files.read_text(root, "hello.txt")
    # External edit invalidates version.
    File.write!(Path.join(root, "hello.txt"), "external\n")
    # mtime resolution is 1s on some FS; ensure separation.
    :timer.sleep(1100)
    File.write!(Path.join(root, "hello.txt"), "external2\n")
    assert {:error, :conflict} = Files.write_text(root, "hello.txt", "client\n", v)
  end

  test "write_text refuses traversal", %{root: root} do
    {:ok, %{version: v}} = Files.read_text(root, "hello.txt")
    assert {:error, :outside_root} = Files.write_text(root, "../escape", "x", v)
  end

  test "write_text refuses binary content", %{root: root} do
    {:ok, %{version: v}} = Files.read_text(root, "hello.txt")
    assert {:error, :binary} = Files.write_text(root, "hello.txt", <<1, 0, 2>>, v)
  end

  test "write_text refuses oversized content", %{root: root} do
    {:ok, %{version: v}} = Files.read_text(root, "hello.txt")
    huge = String.duplicate("a", 2 * 1024 * 1024 + 1)
    assert {:error, :too_large} = Files.write_text(root, "hello.txt", huge, v)
  end

  test "write is atomic — failed rename leaves no temp behind", %{root: root} do
    {:ok, %{version: v}} = Files.read_text(root, "hello.txt")
    {:ok, _} = Files.write_text(root, "hello.txt", "gamma\n", v)
    leftover = File.ls!(root) |> Enum.filter(&String.starts_with?(&1, ".devide.tmp."))
    assert leftover == []
  end
end
