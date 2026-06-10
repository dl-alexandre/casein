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

  test "status_short reports untracked files", %{root: root} do
    File.write!(Path.join(root, "new.txt"), "x\n")
    assert {:ok, [entry]} = Git.status_short(root)
    assert entry.path == "new.txt"
    assert entry.x == "?"
    assert entry.y == "?"
  end

  test "diff returns an empty diff for an unmodified path", %{root: root} do
    assert {:ok, ""} = Git.diff(root, "a.txt")
  end

  test "diff_all returns an empty diff on a clean tree", %{root: root} do
    assert {:ok, ""} = Git.diff_all(root)
  end

  test "diff_all combines diffs across modified tracked files", %{root: root} do
    File.write!(Path.join(root, "b.txt"), "b1\n")
    {_, 0} = System.cmd("git", ["-C", root, "add", "b.txt"])
    {_, 0} = System.cmd("git", ["-C", root, "commit", "-m", "add b"])

    File.write!(Path.join(root, "a.txt"), "2\n")
    File.write!(Path.join(root, "b.txt"), "b2\n")

    assert {:ok, diff} = Git.diff_all(root)
    assert diff =~ "a/a.txt"
    assert diff =~ "a/b.txt"
    assert diff =~ "+2"
    assert diff =~ "+b2"
  end

  test "operations on a missing root fail with :no_root" do
    missing = Path.join(System.tmp_dir!(), "git-missing-#{System.unique_integer([:positive])}")
    refute File.dir?(missing)

    assert {:error, :no_root} = Git.status_short(missing)
    assert {:error, :no_root} = Git.diff(missing, "a.txt")
    assert {:error, :no_root} = Git.diff_all(missing)
  end

  test "status_short fails with a git error outside a repository" do
    root = Path.join(System.tmp_dir!(), "git-norepo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, {:git_exit, code, out}} = Git.status_short(root)
    assert is_integer(code) and code != 0
    assert out =~ "not a git repository"
  end
end
