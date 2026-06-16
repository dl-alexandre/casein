defmodule DevIDE.Git.LocalAdapterTest do
  # Adapter-level security tests for the git shell-out boundary. The facade is
  # covered in DevIDE.GitTest; this file pins the hardening properties that make
  # shelling out to `git` safe: path-traversal/symlink rejection via PathSafety,
  # argv-style invocation (no shell), and the `--` pathspec guard against option
  # injection.
  use ExUnit.Case, async: true

  alias DevIDE.Git.LocalAdapter

  setup do
    root = Path.join(System.tmp_dir!(), "git-adapter-#{System.unique_integer([:positive])}")
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

  describe "diff/2 path safety" do
    test "rejects parent-directory traversal before invoking git", %{root: root} do
      assert {:error, :outside_root} = LocalAdapter.diff(root, "../escape")
      assert {:error, :outside_root} = LocalAdapter.diff(root, "../../etc/passwd")
    end

    test "rejects an absolute path outside the root", %{root: root} do
      assert {:error, :outside_root} = LocalAdapter.diff(root, "/etc/passwd")
    end

    test "rejects excessively deep relative paths", %{root: root} do
      deep = Enum.map_join(1..40, "/", fn _ -> "x" end)
      assert {:error, :too_deep} = LocalAdapter.diff(root, deep)
    end

    test "rejects a symlink that escapes the root", %{root: root} do
      outside =
        Path.join(System.tmp_dir!(), "git-adapter-outside-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)

      link = Path.join(root, "escape-link")
      :ok = File.ln_s(outside, link)

      assert {:error, :symlink_escape} = LocalAdapter.diff(root, "escape-link/secret")
    end
  end

  describe "diff/2 argument-injection hardening" do
    test "treats a flag-looking rel as a pathspec, not a git option", %{root: root} do
      # Without the `--` separator git would parse this as `--output=<file>` and
      # write the diff to an arbitrary path. The `--` guard makes it a (non-
      # matching) pathspec, so the sentinel file is never created.
      sentinel = Path.join(System.tmp_dir!(), "git-inject-#{System.unique_integer([:positive])}")
      File.rm_rf!(sentinel)
      on_exit(fn -> File.rm_rf!(sentinel) end)

      _ = LocalAdapter.diff(root, "--output=#{sentinel}")

      refute File.exists?(sentinel)
    end

    test "does not invoke a shell — metacharacters in rel never execute", %{root: root} do
      sentinel = Path.join(System.tmp_dir!(), "git-shell-#{System.unique_integer([:positive])}")
      File.rm_rf!(sentinel)
      on_exit(fn -> File.rm_rf!(sentinel) end)

      # If the rel were interpolated into a shell command, `touch` would run.
      # argv-style System.cmd treats the whole string as one opaque pathspec.
      _ = LocalAdapter.diff(root, "a.txt; touch #{sentinel}")

      refute File.exists?(sentinel)
    end
  end
end
