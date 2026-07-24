defmodule Casein.Test.GitRepoCase do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]

  def setup_git_repo(_context) do
    tmp = Path.join(tmp_root(), "devide-git-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp) end)
    main = Path.join(tmp, "main")
    worktree = Path.join(tmp, "feature-worktree")
    detached_worktree = Path.join(tmp, "detached-worktree")

    File.rm_rf!(tmp)
    File.mkdir_p!(main)

    git!(main, ["init", "--initial-branch=main"])
    git!(main, ["config", "user.name", "Test"])
    git!(main, ["config", "user.email", "test@example.com"])

    File.write!(Path.join(main, "README.md"), "# Test Repo\n")
    git!(main, ["add", "README.md"])
    git!(main, ["commit", "-m", "init"])

    git!(main, ["worktree", "add", "-b", "feature-test", worktree, "main"])
    commit_sha = git!(main, ["rev-parse", "HEAD"])
    git!(main, ["worktree", "add", "--detach", detached_worktree, commit_sha])

    %{tmp: tmp, main: main, worktree: worktree, detached_worktree: detached_worktree}
  end

  def git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end

  def tmp_root do
    root = System.get_env("DEV_IDE_TEST_TMPDIR") || System.tmp_dir!()
    File.mkdir_p!(root)
    root
  end
end
