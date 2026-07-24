defmodule Scripts.PreCommitHookTest do
  use ExUnit.Case, async: true

  @hook Path.expand("../../.githooks/pre-commit", __DIR__)

  test "pre-commit blocks commits on master in the primary checkout" do
    %{repo: repo} = git_fixture!()

    {output, status} = run_hook(repo)

    assert status != 0
    assert output =~ "refusing commit on master"
    assert output =~ "read-only"
  end

  test "pre-commit allows commits on master inside a linked worktree" do
    %{repo: repo} = git_fixture!()

    # Sibling of the fixture repo, deleted defensively before use: /tmp is
    # shared and persistent on the self-hosted runner, and unique_integer
    # values repeat across BEAM restarts — a leftover dir from a crashed run
    # (cleanup never ran) made `git worktree add` fail every gate run that
    # drew the same counter ("fatal: ... already exists").
    worktree = repo <> "-linked-wt"
    File.rm_rf!(worktree)
    on_exit(fn -> File.rm_rf!(worktree) end)

    # Only one checkout may hold `master` — move primary to a branch first.
    git!(repo, ["checkout", "-b", "agent/test/primary"])
    git!(repo, ["worktree", "add", worktree, "master"])

    {output, status} = run_hook(worktree)

    assert status == 0
    refute output =~ "refusing commit on master"
  end

  test "pre-commit allows commits on feature branches in the primary checkout" do
    %{repo: repo} = git_fixture!()
    git!(repo, ["checkout", "-b", "agent/test/feature"])

    {output, status} = run_hook(repo)

    assert status == 0
    refute output =~ "refusing commit on master"
  end

  test "pre-commit honors DEVIDE_ALLOW_MASTER_COMMIT bypass" do
    %{repo: repo} = git_fixture!()

    {output, status} =
      run_hook(repo, env: [{"DEVIDE_ALLOW_MASTER_COMMIT", "1"}])

    assert status == 0
    refute output =~ "refusing commit on master"
  end

  defp run_hook(cwd, opts \\ []) do
    env = Keyword.get(opts, :env, [])

    System.cmd(
      "bash",
      [@hook],
      cd: cwd,
      env: [{"GIT_DIR", Path.join(cwd, ".git")} | env],
      stderr_to_stdout: true
    )
  end

  defp git_fixture! do
    root = System.get_env("CASEIN_TEST_TMPDIR") || System.tmp_dir!()
    repo = Path.join(root, "devide-pre-commit-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    git!(repo, ["init", "--initial-branch=master"])
    git!(repo, ["config", "user.name", "Test"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "# Test\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "init"])

    on_exit(fn -> File.rm_rf!(repo) end)
    %{repo: repo}
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end
end
