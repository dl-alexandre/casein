defmodule DevIDE.FilesTest do
  use DevIDE.TestCase, async: true
  alias DevIDE.Files

  setup do
    root = Path.join(System.tmp_dir!(), "files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, ".git"))
    File.mkdir_p!(Path.join(root, "_build"))
    File.write!(Path.join([root, "lib", "a.ex"]), "defmodule A, do: nil\n")
    File.write!(Path.join(root, "README.md"), "# hi\n")
    File.write!(Path.join(root, "blob.bin"), <<0, 1, 2, 3>>)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "list filters .git/_build and sorts dirs first", %{root: root} do
    {:ok, entries} = Files.list(root, "")
    names = Enum.map(entries, & &1.name)
    refute ".git" in names
    refute "_build" in names
    assert "lib" in names
    # dir before file
    assert Enum.find_index(names, &(&1 == "lib")) <
             Enum.find_index(names, &(&1 == "README.md"))
  end

  test "read_text returns content for small text files", %{root: root} do
    assert {:ok, %{content: "# hi\n", size: 5}} = Files.read_text(root, "README.md")
  end

  test "read_text refuses binaries", %{root: root} do
    assert {:error, :binary} = Files.read_text(root, "blob.bin")
  end

  test "read_text refuses path traversal", %{root: root} do
    assert {:error, :outside_root} = Files.read_text(root, "../escape")
  end
end
