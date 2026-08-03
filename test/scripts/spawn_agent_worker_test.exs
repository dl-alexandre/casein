defmodule Scripts.SpawnAgentWorkerTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/spawn-agent-worker.sh", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  # A worker must branch off the *primary* repo. When CASEIN_CHECKOUT points at
  # the orchestrator's own linked worktree, the resolver has to redirect to the
  # main working tree — otherwise launch-casein-agent.sh adopts the linked
  # worktree in place and the worker silently shares the orchestrator's branch.
  test "dry run resolves a linked-worktree CASEIN_CHECKOUT to the primary repo" do
    tmp = Path.join(System.tmp_dir!(), "spawn-worker-#{System.unique_integer([:positive])}")
    primary = Path.join(tmp, "primary")
    linked = Path.join(tmp, "linked")
    fakebin = Path.join(tmp, "bin")
    File.mkdir_p!(primary)
    File.mkdir_p!(fakebin)
    env_file = Path.join(tmp, "env.sh")

    File.write!(
      env_file,
      "export CASEIN_API_TOKEN='test-token'\nexport CASEIN_WORKSPACE_ID='test-ws'\n"
    )

    on_exit(fn -> File.rm_rf!(tmp) end)

    git = fn args -> {_, 0} = System.cmd("git", ["-C", primary | args], env: git_env()) end
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "master", primary], env: git_env())
    git.(["commit", "-q", "--allow-empty", "-m", "root"])
    {_, 0} = System.cmd("git", ["-C", primary, "worktree", "add", "-q", linked], env: git_env())

    # Stub tmux so `has-session` succeeds and the dry run never touches a server.
    File.write!(Path.join(fakebin, "tmux"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    {out, 0} =
      System.cmd("bash", [@script, "grok", "iso", "casein_test_u-x"],
        env: [
          {"CASEIN_SPAWN_DRY_RUN", "1"},
          {"CASEIN_CHECKOUT", linked},
          {"PATH", fakebin <> ":" <> System.get_env("PATH")},
          # Satisfy agent_env_resolve's first branch (already-exported creds) so
          # the script doesn't abort looking for a Casein tmux pane / env file.
          {"CASEIN_API_TOKEN", "test-token"},
          {"CASEIN_WORKSPACE_ID", "test-ws"},
          {"CASEIN_AGENT_ENV_FILE", env_file}
        ]
      )

    # Tolerant of git/realpath normalization: the resolved checkout must be the
    # primary working tree, never the linked worktree it was invoked from.
    assert out =~ ~r{^checkout=\S*/primary$}m
    assert out =~ ~r{export CASEIN_CHECKOUT=\S*/primary\b}
    refute out =~ ~r{^checkout=\S*/linked$}m
  end

  test "cross-repo dry run sources pairing env and uses Casein's launcher" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "spawn-worker-cross-repo-#{System.unique_integer([:positive])}"
      )

    product = Path.join(tmp, "product")
    fakebin = Path.join(tmp, "bin")
    env_file = Path.join(tmp, "env.sh")
    File.mkdir_p!(product)
    File.mkdir_p!(fakebin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "develop", product], env: git_env())

    {_, 0} =
      System.cmd("git", ["-C", product, "commit", "-q", "--allow-empty", "-m", "root"],
        env: git_env()
      )

    File.write!(
      env_file,
      "export CASEIN_API_TOKEN='test-token'\nexport CASEIN_WORKSPACE_ID='test-ws'\n"
    )

    File.write!(Path.join(fakebin, "tmux"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    {out, 0} =
      System.cmd("bash", [@script, "grok", "audit", "casein_test_u-audit"],
        env: [
          {"CASEIN_SPAWN_DRY_RUN", "1"},
          {"CASEIN_CHECKOUT", product},
          {"CASEIN_API_TOKEN", "test-token"},
          {"CASEIN_WORKSPACE_ID", "test-ws"},
          {"CASEIN_AGENT_ENV_FILE", env_file},
          {"PATH", fakebin <> ":" <> System.get_env("PATH")}
        ]
      )

    casein_root = Path.expand("../..", __DIR__)
    casein_launcher = Path.join(casein_root, "scripts/launch-casein-agent.sh")

    assert out =~ "env_file=#{env_file}"
    assert out =~ "launcher=#{casein_launcher}"
    assert out =~ "source #{env_file}"
    assert out =~ "export CASEIN_TMUX_SESSION=casein_test_u-audit"
    assert out =~ "CASEIN_GIT_DIR CASEIN_SCRIPTS"
    assert out =~ "bash #{casein_launcher} grok"
    refute out =~ Path.join(product, "scripts/launch-casein-agent.sh")
    refute out =~ "test-token"
  end

  test "fails clearly when the resolved workspace has no materialized env file" do
    tmp =
      Path.join(System.tmp_dir!(), "spawn-worker-no-env-#{System.unique_integer([:positive])}")

    product = Path.join(tmp, "product")
    fakebin = Path.join(tmp, "bin")
    File.mkdir_p!(product)
    File.mkdir_p!(fakebin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "master", product], env: git_env())

    {_, 0} =
      System.cmd("git", ["-C", product, "commit", "-q", "--allow-empty", "-m", "root"],
        env: git_env()
      )

    File.write!(Path.join(fakebin, "tmux"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    {out, status} =
      System.cmd("bash", [@script, "grok", "audit", "casein_test_u-audit"],
        env: [
          {"CASEIN_SPAWN_DRY_RUN", "1"},
          {"CASEIN_CHECKOUT", product},
          {"CASEIN_API_TOKEN", "test-token"},
          {"CASEIN_WORKSPACE_ID", "test-ws"},
          {"CASEIN_AGENT_ENV_FILE", Path.join(tmp, "missing-env.sh")},
          {"CASEIN_AGENT_MCP_HOME", Path.join(tmp, "missing-staging")},
          {"PATH", fakebin <> ":" <> System.get_env("PATH")}
        ],
        stderr_to_stdout: true
      )

    assert status == 1
    assert out =~ "workspace pairing env not found"
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
