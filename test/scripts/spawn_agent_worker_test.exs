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

  # A managed Grok worker's bwrap sandbox base is frozen when its leader starts,
  # so spawning into a locked workspace yields a pane that reaches a normal
  # prompt but cannot write, reach the network, or run mix — and re-granting the
  # unlock afterwards does not free it. Whole fan-outs have been spawned dead
  # this way, so the spawn must refuse rather than warn.
  test "refuses to spawn a Grok worker while the workspace agent-write unlock is locked" do
    ctx =
      preflight_fixture!(
        "locked",
        ~s({"agent_write":{"write_enabled":false,"unlock_status":"expired"}})
      )

    {out, status} = spawn_dry_run(ctx, "grok", [])

    assert status == 3
    assert out =~ "refusing to spawn a Grok worker"
    assert out =~ "agent write is unavailable (expired)"
    assert out =~ "frozen at launch"
    assert out =~ "re-grant agent write for the workspace"
    assert out =~ "spawn-agent-worker.sh codex"
    # It must not have gotten as far as describing a window to open.
    refute out =~ "window=worker-"
  end

  # write_enabled can be false while the unlock is live — the workspace may not
  # be in manual mode, or its DB isolation may be shared_stage/unsafe. Telling
  # the operator to re-grant there sends them down a dead end.
  test "does not blame the unlock when a live unlock is overridden by workspace policy" do
    ctx =
      preflight_fixture!(
        "policy",
        ~s({"agent_write":{"write_enabled":false,"unlock_status":"active"}})
      )

    {out, status} = spawn_dry_run(ctx, "grok", [])

    assert status == 3
    assert out =~ "agent write is unavailable (blocked-by-workspace-policy)"
    assert out =~ "The unlock itself is active"
    assert out =~ "shared_stage/unsafe"
    refute out =~ "Fix: re-grant agent write for the workspace"
  end

  test "spawns a Grok worker when the workspace reports an active unlock" do
    ctx =
      preflight_fixture!(
        "unlocked",
        ~s({"agent_write":{"write_enabled":true,"unlock_status":"active"}})
      )

    {out, 0} = spawn_dry_run(ctx, "grok", [])

    assert out =~ "window=worker-iso"
    refute out =~ "refusing to spawn"
  end

  test "CASEIN_SPAWN_ALLOW_READ_ONLY spawns a deliberately read-only Grok worker" do
    ctx = preflight_fixture!("override", ~s({"agent_write":{"write_enabled":false}}))

    {out, 0} = spawn_dry_run(ctx, "grok", [{"CASEIN_SPAWN_ALLOW_READ_ONLY", "1"}])

    assert out =~ "window=worker-iso"
    refute out =~ "refusing to spawn"
  end

  # codex is not gated by the workspace unlock, so the preflight must not touch it.
  test "does not preflight non-Grok runtimes" do
    ctx = preflight_fixture!("codex", ~s({"agent_write":{"write_enabled":false}}))

    {out, 0} = spawn_dry_run(ctx, "codex", [])

    assert out =~ "window=worker-iso"
    refute out =~ "refusing to spawn"
  end

  # A degraded control plane must not make spawning impossible — the launcher's
  # own startup announce still covers that case.
  test "warns but proceeds when the workspace write state cannot be determined" do
    ctx = preflight_fixture!("unreachable", :fail)

    {out, 0} = spawn_dry_run(ctx, "grok", [])

    assert out =~ "could not confirm this workspace's agent-write unlock"
    assert out =~ "window=worker-iso"
  end

  # Builds a checkout plus stub tmux/curl on PATH. `body` is the JSON the status
  # endpoint returns, or :fail to simulate an unreachable control plane.
  defp preflight_fixture!(label, body) do
    tmp =
      Path.join(System.tmp_dir!(), "spawn-worker-#{label}-#{System.unique_integer([:positive])}")

    product = Path.join(tmp, "product")
    fakebin = Path.join(tmp, "bin")
    env_file = Path.join(tmp, "env.sh")
    File.mkdir_p!(product)
    File.mkdir_p!(fakebin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "master", product], env: git_env())

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

    curl =
      case body do
        :fail -> "#!/usr/bin/env bash\nexit 22\n"
        json -> "#!/usr/bin/env bash\ncat <<'JSON'\n#{json}\nJSON\n"
      end

    File.write!(Path.join(fakebin, "curl"), curl)
    File.chmod!(Path.join(fakebin, "curl"), 0o755)

    %{product: product, fakebin: fakebin, env_file: env_file}
  end

  defp spawn_dry_run(ctx, runtime, extra_env) do
    System.cmd("bash", [@script, runtime, "iso", "casein_test_u-x"],
      env:
        [
          {"CASEIN_SPAWN_DRY_RUN", "1"},
          {"CASEIN_CHECKOUT", ctx.product},
          {"CASEIN_API_TOKEN", "test-token"},
          {"CASEIN_WORKSPACE_ID", "test-ws"},
          {"CASEIN_API_BASE_URL", "http://127.0.0.1:4000"},
          {"CASEIN_AGENT_ENV_FILE", ctx.env_file},
          {"PATH", ctx.fakebin <> ":" <> System.get_env("PATH")}
        ] ++ extra_env,
      stderr_to_stdout: true
    )
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
