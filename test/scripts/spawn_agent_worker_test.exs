defmodule Scripts.SpawnAgentWorkerTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/spawn-agent-worker.sh", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  # A worker must branch off the *primary* repo. When DEVIDE_CHECKOUT points at
  # the orchestrator's own linked worktree, the resolver has to redirect to the
  # main working tree — otherwise launch-devide-agent.sh adopts the linked
  # worktree in place and the worker silently shares the orchestrator's branch.
  test "dry run resolves a linked-worktree DEVIDE_CHECKOUT to the primary repo" do
    tmp = Path.join(System.tmp_dir!(), "spawn-worker-#{System.unique_integer([:positive])}")
    primary = Path.join(tmp, "primary")
    linked = Path.join(tmp, "linked")
    fakebin = Path.join(tmp, "bin")
    File.mkdir_p!(primary)
    File.mkdir_p!(fakebin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    git = fn args -> {_, 0} = System.cmd("git", ["-C", primary | args], env: git_env()) end
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "master", primary], env: git_env())
    git.(["commit", "-q", "--allow-empty", "-m", "root"])
    {_, 0} = System.cmd("git", ["-C", primary, "worktree", "add", "-q", linked], env: git_env())

    # Stub tmux so `has-session` succeeds and the dry run never touches a server.
    File.write!(Path.join(fakebin, "tmux"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    {out, 0} =
      System.cmd("bash", [@script, "grok", "iso", "devide_test_u-x"],
        env: [
          {"DEVIDE_SPAWN_DRY_RUN", "1"},
          {"DEVIDE_CHECKOUT", linked},
          {"PATH", fakebin <> ":" <> System.get_env("PATH")},
          # Satisfy agent_env_resolve's first branch (already-exported creds) so
          # the script doesn't abort looking for a DevIDE tmux pane / env file.
          {"DEV_IDE_API_TOKEN", "test-token"},
          {"DEVIDE_WORKSPACE_ID", "test-ws"}
        ]
      )

    # Tolerant of git/realpath normalization: the resolved checkout must be the
    # primary working tree, never the linked worktree it was invoked from.
    assert out =~ ~r{^checkout=\S*/primary$}m
    assert out =~ ~r{export DEVIDE_CHECKOUT=\S*/primary\b}
    refute out =~ ~r{^checkout=\S*/linked$}m
  end

  defp git_env do
    [
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@t"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@t"}
    ]
  end
end
