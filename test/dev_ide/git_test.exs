defmodule DevIDE.GitTest do
  use ExUnit.Case, async: true
  alias DevIDE.Git

  setup do
    root = Path.join(System.tmp_dir!(), "git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {_, 0} =
      System.cmd("git", ["-C", root, "init", "--initial-branch=main"], stderr_to_stdout: true)

    {_, 0} = System.cmd("git", ["-C", root, "config", "user.email", "t@t"])
    {_, 0} = System.cmd("git", ["-C", root, "config", "user.name", "t"])
    File.write!(Path.join(root, "a.txt"), "1\n")
    {_, 0} = System.cmd("git", ["-C", root, "add", "a.txt"])
    {_, 0} = System.cmd("git", ["-C", root, "commit", "-m", "init"])
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "status_short shows nothing on a clean tree", %{root: root} do
    assert {:ok, []} = Git.status_short(root)
  end

  test "status_short reports modified files", %{root: root} do
    File.write!(Path.join(root, "a.txt"), "2\n")
    {:ok, [entry]} = Git.status_short(root)
    assert entry.path == "a.txt"
  end

  test "diff returns the unified diff for a modified path", %{root: root} do
    File.write!(Path.join(root, "a.txt"), "2\n")
    {:ok, diff} = Git.diff(root, "a.txt")
    assert diff =~ "-1"
    assert diff =~ "+2"
  end

  test "diff refuses path traversal — never invokes git on escape", %{root: root} do
    assert {:error, :outside_root} = Git.diff(root, "../escape")
  end
end
