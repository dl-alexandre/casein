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
    home = Path.join(tmp, "home")
    File.mkdir_p!(primary)
    File.mkdir_p!(fakebin)
    env_file = stage_session_env!(home, "test", "test-ws")

    on_exit(fn -> File.rm_rf!(tmp) end)

    git = fn args -> {_, 0} = System.cmd("git", ["-C", primary | args], env: git_env()) end
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "master", primary], env: git_env())
    git.(["commit", "-q", "--allow-empty", "-m", "root"])
    {_, 0} = System.cmd("git", ["-C", primary, "worktree", "add", "-q", linked], env: git_env())

    # Stub tmux so `has-session` succeeds and the dry run never touches a server.
    File.write!(Path.join(fakebin, "tmux"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    headroom = healthy_headroom_env(tmp)

    {out, 0} =
      System.cmd("bash", [@script, "grok", "iso", "casein_test_u-x"],
        env:
          [
            {"CASEIN_SPAWN_DRY_RUN", "1"},
            # The budget gate reads the host's real `ps`, so without pinning it these
            # tests pass or fail by how many agents happen to be resident on the box
            # running them. They are about dry-run pairing and headroom, not budget;
            # 0 disables the limit. Budget coverage lives in Scripts.AgentBudgetTest.
            {"CASEIN_AGENT_MAX_TOTAL", "0"},
            {"CASEIN_CHECKOUT", linked},
            {"HOME", home},
            {"PATH", fakebin <> ":" <> System.get_env("PATH")},
            # Satisfy agent_env_resolve's first branch (already-exported creds) so
            # the script doesn't abort looking for a Casein tmux pane / env file.
            {"CASEIN_API_TOKEN", "test-token"},
            {"CASEIN_WORKSPACE_ID", "test-ws"},
            {"CASEIN_WORKSPACE_NAME", "test"},
            {"CASEIN_AGENT_ENV_FILE", env_file}
          ] ++ headroom
      )

    # Tolerant of git/realpath normalization: the resolved checkout must be the
    # primary working tree, never the linked worktree it was invoked from.
    assert out =~ ~r{^checkout=\S*/primary$}m
    assert out =~ ~r{export CASEIN_CHECKOUT=\S*/primary\b}
    refute out =~ ~r{^checkout=\S*/linked$}m
  end

  # The dry-run test above passes even against the broken resolver, because its
  # fixture has two worktrees: `git worktree list` finishes writing before the
  # consumer stops reading, so nothing ever gets SIGPIPE'd. On a real checkout
  # (41 worktrees) git is still emitting when the consumer quits, the pipeline
  # reports failure under `set -o pipefail`, and the resolver silently returned
  # the ORCHESTRATOR's worktree — the exact outcome it exists to prevent.
  #
  # Reproduce that deterministically with a slow `git` instead of dozens of real
  # worktrees: emit the primary, flush, then keep writing. Any implementation
  # that stops reading early fails here.
  test "primary resolution survives a git that is still writing when parsing stops" do
    tmp =
      Path.join(System.tmp_dir!(), "spawn-worker-sigpipe-#{System.unique_integer([:positive])}")

    primary = Path.join(tmp, "primary")
    linked = Path.join(tmp, "linked")
    fakebin = Path.join(tmp, "bin")
    Enum.each([primary, linked, fakebin], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf!(tmp) end)

    File.write!(Path.join(fakebin, "git"), """
    #!/usr/bin/env bash
    printf 'worktree %s\\nHEAD 0000\\nbranch refs/heads/master\\n\\n' "#{primary}"
    sleep 0.4
    for i in $(seq 1 200); do
      printf 'worktree %s/w$i\\nHEAD 0000\\ndetached\\n\\n' "#{tmp}"
    done
    """)

    File.chmod!(Path.join(fakebin, "git"), 0o755)

    resolver =
      @script
      |> File.read!()
      |> then(fn text ->
        [_, body] = String.split(text, "\nspawn_worker_resolve_primary_checkout() {\n", parts: 2)
        [body, _] = String.split(body, "\n}\n", parts: 2)
        "spawn_worker_resolve_primary_checkout() {\n#{body}\n}"
      end)

    script = """
    set -euo pipefail
    #{resolver}
    spawn_worker_resolve_primary_checkout '#{linked}'
    """

    {out, 0} =
      System.cmd("bash", ["-c", script],
        env: [{"PATH", fakebin <> ":" <> System.get_env("PATH")}]
      )

    assert String.trim(out) == primary
    refute String.trim(out) == linked
  end

  test "cross-repo dry run sources pairing env and uses Casein's launcher" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "spawn-worker-cross-repo-#{System.unique_integer([:positive])}"
      )

    product = Path.join(tmp, "product")
    fakebin = Path.join(tmp, "bin")
    home = Path.join(tmp, "home")
    File.mkdir_p!(product)
    File.mkdir_p!(fakebin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "develop", product], env: git_env())

    {_, 0} =
      System.cmd("git", ["-C", product, "commit", "-q", "--allow-empty", "-m", "root"],
        env: git_env()
      )

    env_file = stage_session_env!(home, "test", "test-ws")

    File.write!(Path.join(fakebin, "tmux"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    headroom = healthy_headroom_env(tmp)

    {out, 0} =
      System.cmd("bash", [@script, "grok", "audit", "casein_test_u-audit"],
        env:
          [
            {"CASEIN_SPAWN_DRY_RUN", "1"},
            {"CASEIN_AGENT_MAX_TOTAL", "0"},
            {"CASEIN_CHECKOUT", product},
            {"HOME", home},
            {"CASEIN_API_TOKEN", "test-token"},
            {"CASEIN_WORKSPACE_ID", "test-ws"},
            {"CASEIN_WORKSPACE_NAME", "test"},
            {"CASEIN_AGENT_ENV_FILE", env_file},
            {"PATH", fakebin <> ":" <> System.get_env("PATH")}
          ] ++ headroom
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
    home = Path.join(tmp, "home")
    File.mkdir_p!(product)
    File.mkdir_p!(fakebin)
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "master", product], env: git_env())

    {_, 0} =
      System.cmd("git", ["-C", product, "commit", "-q", "--allow-empty", "-m", "root"],
        env: git_env()
      )

    File.write!(Path.join(fakebin, "tmux"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    headroom = healthy_headroom_env(tmp)

    {out, status} =
      System.cmd("bash", [@script, "grok", "audit", "casein_test_u-audit"],
        env:
          [
            {"CASEIN_SPAWN_DRY_RUN", "1"},
            {"CASEIN_AGENT_MAX_TOTAL", "0"},
            {"CASEIN_CHECKOUT", product},
            {"HOME", home},
            {"CASEIN_API_TOKEN", "test-token"},
            {"CASEIN_WORKSPACE_ID", "test-ws"},
            {"CASEIN_WORKSPACE_NAME", "caller-ws"},
            {"CASEIN_AGENT_ENV_FILE", Path.join(tmp, "missing-env.sh")},
            {"CASEIN_AGENT_MCP_HOME", Path.join(tmp, "missing-staging")},
            {"PATH", fakebin <> ":" <> System.get_env("PATH")}
          ] ++ headroom,
        stderr_to_stdout: true
      )

    assert status == 1
    assert out =~ "workspace pairing env not found"
    assert out =~ "target_workspace=test"
  end

  # Fleet bug: A-orchestrator CASEIN_AGENT_* must not pin pairing when the
  # explicit session argument names workspace B. Target session wins.
  test "dry run into workspace B session uses B pairing despite caller A env" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "spawn-worker-cross-ws-#{System.unique_integer([:positive])}"
      )

    product = Path.join(tmp, "product")
    fakebin = Path.join(tmp, "bin")
    home = Path.join(tmp, "home")
    File.mkdir_p!(product)
    File.mkdir_p!(fakebin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "master", product], env: git_env())

    {_, 0} =
      System.cmd("git", ["-C", product, "commit", "-q", "--allow-empty", "-m", "root"],
        env: git_env()
      )

    env_a = stage_session_env!(home, "workspace-a", "ws-a")
    env_b = stage_session_env!(home, "workspace-b", "ws-b")

    File.write!(Path.join(fakebin, "tmux"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    headroom = healthy_headroom_env(tmp)

    {out, 0} =
      System.cmd(
        "bash",
        [@script, "codex", "cross", "casein_workspace-b_art-deadbeef"],
        env:
          [
            {"CASEIN_SPAWN_DRY_RUN", "1"},
            {"CASEIN_AGENT_MAX_TOTAL", "0"},
            {"CASEIN_CHECKOUT", product},
            {"HOME", home},
            {"CASEIN_API_TOKEN", "caller-a-token"},
            {"CASEIN_WORKSPACE_ID", "ws-a"},
            {"CASEIN_WORKSPACE_NAME", "workspace-a"},
            {"CASEIN_AGENT_ENV_FILE", env_a},
            {"CASEIN_AGENT_MCP_HOME", Path.dirname(env_a)},
            {"PATH", fakebin <> ":" <> System.get_env("PATH")}
          ] ++ headroom
      )

    assert out =~ "env_file=#{env_b}"
    assert out =~ "source #{env_b}"
    assert out =~ "export CASEIN_TMUX_SESSION=casein_workspace-b_art-deadbeef"
    refute out =~ "env_file=#{env_a}"
    refute out =~ "source #{env_a}"
  end

  test "dry run recovers a stale CASEIN_CHECKOUT from the target env's primary scripts tree" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "spawn-worker-stale-recover-#{System.unique_integer([:positive])}"
      )

    product = Path.join(tmp, "product")
    fakebin = Path.join(tmp, "bin")
    home = Path.join(tmp, "home")
    stale = Path.join(tmp, "gone-worktree")
    File.mkdir_p!(product)
    File.mkdir_p!(fakebin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "master", product], env: git_env())

    {_, 0} =
      System.cmd("git", ["-C", product, "commit", "-q", "--allow-empty", "-m", "root"],
        env: git_env()
      )

    env_file =
      stage_session_env!(
        home,
        "test",
        "test-ws",
        "export CASEIN_CHECKOUT=#{inspect(stale)}\nexport CASEIN_SCRIPTS=#{inspect(Path.join(product, "scripts"))}\n"
      )

    File.write!(Path.join(fakebin, "tmux"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    {out, 0} =
      System.cmd("bash", [@script, "codex", "recover", "casein_test_u-x"],
        env:
          [
            {"CASEIN_SPAWN_DRY_RUN", "1"},
            {"CASEIN_AGENT_MAX_TOTAL", "0"},
            {"CASEIN_CHECKOUT", stale},
            {"HOME", home},
            {"CASEIN_API_TOKEN", "test-token"},
            {"CASEIN_WORKSPACE_ID", "test-ws"},
            {"CASEIN_WORKSPACE_NAME", "test"},
            {"CASEIN_AGENT_ENV_FILE", env_file},
            {"PATH", fakebin <> ":" <> System.get_env("PATH")}
          ] ++ healthy_headroom_env(tmp),
        stderr_to_stdout: true
      )

    assert out =~ "recovered stale CASEIN_CHECKOUT=#{stale}"
    assert out =~ "checkout=#{product}"
    assert out =~ "source=#{env_file}"
  end

  test "stale CASEIN_CHECKOUT fails with its env.sh source and opens nothing" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "spawn-worker-stale-diagnostic-#{System.unique_integer([:positive])}"
      )

    fakebin = Path.join(tmp, "bin")
    home = Path.join(tmp, "home")
    stale = Path.join(tmp, "gone-worktree")
    tmux_log = Path.join(tmp, "tmux.log")
    File.mkdir_p!(fakebin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    env_file =
      stage_session_env!(
        home,
        "test",
        "test-ws",
        "export CASEIN_CHECKOUT=#{inspect(stale)}\n"
      )

    File.write!(
      Path.join(fakebin, "tmux"),
      "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >>\"#{tmux_log}\"\nexit 0\n"
    )

    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    {out, 1} =
      System.cmd("bash", [@script, "codex", "diagnostic", "casein_test_u-x"],
        env:
          [
            {"CASEIN_CHECKOUT", stale},
            {"HOME", home},
            {"CASEIN_API_TOKEN", "test-token"},
            {"CASEIN_WORKSPACE_ID", "test-ws"},
            {"CASEIN_WORKSPACE_NAME", "test"},
            {"CASEIN_AGENT_ENV_FILE", env_file},
            {"PATH", fakebin <> ":" <> System.get_env("PATH")}
          ] ++ healthy_headroom_env(tmp),
        stderr_to_stdout: true
      )

    assert out =~ "CASEIN_CHECKOUT=#{stale}"
    assert out =~ "env.sh source=#{env_file}"
    assert out =~ "could not recover an existing primary checkout"
    refute File.exists?(tmux_log)
  end

  # Isolation no longer selects the bwrap base — that is always "strict" — so a
  # worker spawned into a locked workspace still writes its worktree, runs mix,
  # and commits. Only pane control is withheld. Refusing the spawn (as this did
  # while the two were coupled) would now block a worker that works, so the
  # preflight must advise and proceed.
  test "spawns a Grok worker while the MCP grant is locked, with an advisory" do
    ctx =
      preflight_fixture!(
        "locked",
        ~s({"agent_write":{"write_enabled":false}})
      )

    {out, status} = spawn_dry_run(ctx, "grok", [])

    assert status == 0
    refute out =~ "refusing to spawn"

    # The window must actually be opened — the whole point of not refusing.
    assert out =~ "window=worker-"

    assert out =~ "LOCKED MCP grant (blocked)"
    # Say what still works, or the advisory reads as "this worker is broken".
    assert out =~ "CAN write its worktree, run mix, and commit"
    assert out =~ "CANNOT drive"
    assert out =~ "shared_stage, unsafe, or unknown"
    refute out =~ "grant agent write"
    refute out =~ "Unlock 30"
  end

  test "spawns a Grok worker when the workspace reports write enabled" do
    ctx =
      preflight_fixture!(
        "enabled",
        ~s({"agent_write":{"write_enabled":true}})
      )

    {out, 0} = spawn_dry_run(ctx, "grok", [])

    assert out =~ "window=worker-iso"
    refute out =~ "refusing to spawn"
  end

  test "CASEIN_SPAWN_SKIP_WRITE_PREFLIGHT suppresses the locked-grant advisory" do
    ctx = preflight_fixture!("override", ~s({"agent_write":{"write_enabled":false}}))

    {out, 0} = spawn_dry_run(ctx, "grok", [{"CASEIN_SPAWN_SKIP_WRITE_PREFLIGHT", "1"}])

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

    assert out =~ "could not confirm this workspace's agent-write state"
    assert out =~ "window=worker-iso"
  end

  # `tmux new-window -P` returns a pane id before the launch command has proven
  # it can run, so a worker that dies on startup used to be reported as a
  # success. Callers then brief a pane that will never answer.
  test "reports failure when the worker pane dies immediately" do
    ctx = preflight_fixture!("dead-pane", ~s({"agent_write":{"write_enabled":true}}))

    {out, code} = spawn_worker(ctx, "codex", [{"FAKE_PANE_STATE", "dead"}])

    assert code == 1
    assert out =~ "died immediately after launch"
    # The pane's own output is what tells you *why*.
    assert out =~ "No such file or directory"
    refute out =~ ~r/^%99$/m
  end

  test "does not retry a side-effecting new-window failure and cleans its pane" do
    ctx = preflight_fixture!("new-window-failure", ~s({"agent_write":{"write_enabled":true}}))
    marker = Path.join(Path.dirname(ctx.tmux_log), "new-window-failed")

    {out, code} =
      spawn_worker(ctx, "codex", [
        {"FAKE_NEW_WINDOW_FAIL_ONCE", "1"},
        {"FAKE_NEW_WINDOW_MARKER", marker}
      ])

    assert code == 1
    assert out =~ "launch was not retried"
    calls = tmux_calls(ctx)
    assert length(Regex.scan(~r/new-window/, calls)) == 1
    assert calls =~ "kill-window %98"
    refute calls =~ "new-window %99"
  end

  test "reports failure when the worker window closed with its command" do
    ctx = preflight_fixture!("gone-pane", ~s({"agent_write":{"write_enabled":true}}))

    {out, code} = spawn_worker(ctx, "codex", [{"FAKE_PANE_STATE", "gone"}])

    assert code == 1
    assert out =~ "died immediately after launch"
    refute out =~ ~r/^%99$/m
  end

  test "prints the pane id when the agent process is running in the pane" do
    ctx = preflight_fixture!("live-pane", ~s({"agent_write":{"write_enabled":true}}))

    {out, 0} = spawn_worker(ctx, "codex", [{"FAKE_PANE_STATE", "alive"}])

    assert out =~ ~r/^spawned %99$/m
    assert out =~ ~r/^%99$/m
    refute out =~ "died immediately"
    # A success leaves the window exactly as spawned.
    refute tmux_calls(ctx) =~ "kill-window"
  end

  # The failure this whole readiness gate exists for: the pane outlives its first
  # moment, so the liveness probe passes, but the launcher never reached its exec
  # and the window holds nothing but a shell. Spawn used to print a pane id for
  # that, and the caller briefed a window that could never answer.
  #
  # The stubbed tree still contains the launcher's own
  # `... launch-casein-agent.sh codex` argv, so a pattern loose enough to match
  # the launcher instead of the agent fails here.
  test "reports failure when the window comes up holding only a shell" do
    ctx = preflight_fixture!("shell-only", ~s({"agent_write":{"write_enabled":true}}))

    {out, code} =
      spawn_worker(ctx, "codex", [{"FAKE_PANE_STATE", "alive"}, {"FAKE_AGENT_STATE", "shell"}])

    assert code == 1
    assert out =~ "no codex process appeared in worker pane %99"
    assert out =~ "holds only a shell"
    refute out =~ ~r/^%99$/m
  end

  test "closes the window of a worker that never started an agent" do
    ctx = preflight_fixture!("shell-cleanup", ~s({"agent_write":{"write_enabled":true}}))

    {out, 1} =
      spawn_worker(ctx, "codex", [{"FAKE_PANE_STATE", "alive"}, {"FAKE_AGENT_STATE", "shell"}])

    assert out =~ "closed the failed worker window"
    assert tmux_calls(ctx) =~ "kill-window %99"
  end

  # Sometimes you want the wreckage. Keeping it renames the window so it does not
  # read as a worker waiting for a briefing.
  test "sets remain-on-exit so a dead pane still has launcher stderr" do
    ctx = preflight_fixture!("remain-on-exit", ~s({"agent_write":{"write_enabled":true}}))

    {out, 1} =
      spawn_worker(ctx, "codex", [
        {"FAKE_PANE_STATE", "dead"},
        {"FAKE_AGENT_STATE", "shell"},
        {"CASEIN_SPAWN_PROBE_SECONDS", "0"}
      ])

    assert tmux_calls(ctx) =~ "set-option"
    assert out =~ "launch-casein-agent.sh: No such file or directory"
  end

  test "CASEIN_SPAWN_KEEP_FAILED_WINDOW marks the window failed instead of closing it" do
    ctx = preflight_fixture!("shell-keep", ~s({"agent_write":{"write_enabled":true}}))

    {out, 1} =
      spawn_worker(ctx, "codex", [
        {"FAKE_PANE_STATE", "alive"},
        {"FAKE_AGENT_STATE", "shell"},
        {"CASEIN_SPAWN_KEEP_FAILED_WINDOW", "1"}
      ])

    assert out =~ "failed-worker-iso"
    assert tmux_calls(ctx) =~ "rename-window failed-worker-iso"
    refute tmux_calls(ctx) =~ "kill-window"
  end

  test "reports failure when the pane dies while the agent is starting" do
    ctx = preflight_fixture!("dies-starting", ~s({"agent_write":{"write_enabled":true}}))

    {out, code} =
      spawn_worker(ctx, "codex", [
        {"FAKE_PANE_STATE", "dead"},
        {"FAKE_AGENT_STATE", "shell"},
        {"CASEIN_SPAWN_PROBE_SECONDS", "0"}
      ])

    assert code == 1
    assert out =~ "died while codex was starting"
    refute out =~ ~r/^%99$/m
  end

  test "the readiness checks can be waived by callers running their own" do
    ctx = preflight_fixture!("waived", ~s({"agent_write":{"write_enabled":true}}))

    {out, 0} =
      spawn_worker(ctx, "codex", [
        {"FAKE_PANE_STATE", "dead"},
        {"FAKE_AGENT_STATE", "shell"},
        {"CASEIN_SPAWN_PROBE_SECONDS", "0"},
        {"CASEIN_SPAWN_READY_SECONDS", "0"}
      ])

    assert out =~ ~r/^%99$/m
  end

  # Builds a checkout plus stub tmux/curl on PATH. `body` is the JSON the status
  # endpoint returns, or :fail to simulate an unreachable control plane.
  defp preflight_fixture!(label, body) do
    tmp =
      Path.join(System.tmp_dir!(), "spawn-worker-#{label}-#{System.unique_integer([:positive])}")

    product = Path.join(tmp, "product")
    fakebin = Path.join(tmp, "bin")
    home = Path.join(tmp, "home")
    File.mkdir_p!(product)
    File.mkdir_p!(fakebin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "master", product], env: git_env())

    {_, 0} =
      System.cmd("git", ["-C", product, "commit", "-q", "--allow-empty", "-m", "root"],
        env: git_env()
      )

    # Session arg in helpers is casein_test_u-x → workspace name "test".
    env_file = stage_session_env!(home, "test", "test-ws")

    # Stub tmux: `has-session` succeeds, `new-window` hands back a pane id,
    # `list-panes` reports whatever liveness FAKE_PANE_STATE asks for, and
    # `display-message` hands back the pane's root pid so the readiness walk has
    # somewhere to start. Window disposal is journalled for assertions.
    # casein_tmux always prefixes `-L <label>` (#248). Strip that before the
    # subcommand case so the stub still matches list-panes/new-window/etc.
    File.write!(Path.join(fakebin, "tmux"), """
    #!/usr/bin/env bash
    if [[ "${1:-}" == "-L" || "${1:-}" == "-S" ]]; then
      shift 2
    fi
    case "${1:-}" in
      list-panes)
        case "${FAKE_PANE_STATE:-alive}" in
          alive) printf '%%99 0\\n' ;;
          dead) printf '%%99 1\\n' ;;
          gone) : ;;
        esac
        ;;
      new-window)
        if [[ "${FAKE_NEW_WINDOW_FAIL_ONCE:-0}" == "1" && ! -e "${FAKE_NEW_WINDOW_MARKER:?}" ]]; then
          : >"${FAKE_NEW_WINDOW_MARKER}"
          [[ -n "${FAKE_TMUX_LOG:-}" ]] && printf 'new-window %%98\\n' >>"${FAKE_TMUX_LOG}"
          printf '%%98\\n'
          exit 1
        fi
        [[ -n "${FAKE_TMUX_LOG:-}" ]] && printf 'new-window %%99\\n' >>"${FAKE_TMUX_LOG}"
        printf '%%99\\n'
        ;;
      display-message) printf '424242\\n' ;;
      kill-window | rename-window | set-option | set-window-option)
        [[ -n "${FAKE_TMUX_LOG:-}" ]] && printf '%s %s\\n' "$1" "${*: -1}" >>"$FAKE_TMUX_LOG"
        ;;
      capture-pane)
        printf 'bash: launch-casein-agent.sh: No such file or directory\\n'
        ;;
    esac
    exit 0
    """)

    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    # Stub ps: the pane's process tree. `agent` puts the runtime binary under the
    # pane's root pid; `shell` leaves only the launcher and a bare shell — the
    # window that looks spawned but can never answer.
    File.write!(Path.join(fakebin, "ps"), """
    #!/usr/bin/env bash
    launcher='sh -c source /tmp/env.sh && cd /repo && bash /casein/scripts/launch-casein-agent.sh codex'
    printf '424242 1 %s\\n' "$launcher"
    case "${FAKE_AGENT_STATE:-agent}" in
      agent) printf '424243 424242 /opt/fake/lib/node_modules/@openai/codex/bin/codex.js --mcp\\n' ;;
      shell) printf '424244 424242 bash -i\\n' ;;
    esac
    exit 0
    """)

    File.chmod!(Path.join(fakebin, "ps"), 0o755)

    curl =
      case body do
        :fail -> "#!/usr/bin/env bash\nexit 22\n"
        json -> "#!/usr/bin/env bash\ncat <<'JSON'\n#{json}\nJSON\n"
      end

    File.write!(Path.join(fakebin, "curl"), curl)
    File.chmod!(Path.join(fakebin, "curl"), 0o755)

    # Healthy headroom fixtures so suite runs do not refuse on a loaded fleet box (#863).
    loadavg = Path.join(tmp, "loadavg")
    meminfo = Path.join(tmp, "meminfo")
    File.write!(loadavg, "1.00 1.00 1.00 1/100 1\n")

    File.write!(meminfo, """
    MemTotal:       999999999 kB
    MemFree:        40000000 kB
    MemAvailable:   40000000 kB
    """)

    %{
      product: product,
      fakebin: fakebin,
      home: home,
      env_file: env_file,
      tmux_log: Path.join(tmp, "tmux-calls.log"),
      loadavg: loadavg,
      meminfo: meminfo
    }
  end

  defp headroom_env(ctx) do
    [
      {"CASEIN_SPAWN_LOADAVG_PATH", ctx.loadavg},
      {"CASEIN_SPAWN_MEMINFO_PATH", ctx.meminfo},
      {"CASEIN_SPAWN_NPROC", "32"},
      {"CASEIN_SPAWN_MAX_LOAD_RATIO", "1.0"},
      {"CASEIN_SPAWN_MIN_MEM_AVAILABLE_KB", "2097152"},
      {"CASEIN_SPAWN_FORCE", "0"}
    ]
  end

  defp spawn_dry_run(ctx, runtime, extra_env) do
    System.cmd("bash", [@script, runtime, "iso", "casein_test_u-x"],
      env:
        [
          {"CASEIN_SPAWN_DRY_RUN", "1"},
          {"CASEIN_AGENT_MAX_TOTAL", "0"},
          {"CASEIN_CHECKOUT", ctx.product},
          {"HOME", ctx.home},
          {"CASEIN_API_TOKEN", "test-token"},
          {"CASEIN_WORKSPACE_ID", "test-ws"},
          {"CASEIN_WORKSPACE_NAME", "test"},
          {"CASEIN_API_BASE_URL", "http://127.0.0.1:4000"},
          {"CASEIN_AGENT_ENV_FILE", ctx.env_file},
          {"PATH", ctx.fakebin <> ":" <> System.get_env("PATH")}
        ] ++ headroom_env(ctx) ++ extra_env,
      stderr_to_stdout: true
    )
  end

  # Non-dry-run: exercises the real new-window + probe + readiness path against
  # stub tmux. Both budgets are trimmed so the passing cases do not idle for the
  # full production windows.
  defp spawn_worker(ctx, runtime, extra_env) do
    System.cmd("bash", [@script, runtime, "iso", "casein_test_u-x"],
      env:
        [
          {"CASEIN_CHECKOUT", ctx.product},
          {"HOME", ctx.home},
          {"CASEIN_API_TOKEN", "test-token"},
          {"CASEIN_WORKSPACE_ID", "test-ws"},
          {"CASEIN_WORKSPACE_NAME", "test"},
          {"CASEIN_API_BASE_URL", "http://127.0.0.1:4000"},
          {"CASEIN_AGENT_ENV_FILE", ctx.env_file},
          {"CASEIN_SPAWN_PROBE_SECONDS", "1"},
          {"CASEIN_SPAWN_READY_SECONDS", "2"},
          {"FAKE_TMUX_LOG", ctx.tmux_log},
          {"PATH", ctx.fakebin <> ":" <> System.get_env("PATH")}
        ] ++ headroom_env(ctx) ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp tmux_calls(ctx) do
    case File.read(ctx.tmux_log) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end

  # Session-first env resolve looks up ~/.casein/agent-mcp/<workspace>/env.sh
  # from the casein_<workspace>_* session name. Stage that path under a fake HOME.
  defp stage_session_env!(home, workspace_name, workspace_id, extra \\ "") do
    dir = Path.join([home, ".casein", "agent-mcp", workspace_name])
    File.mkdir_p!(dir)
    env_file = Path.join(dir, "env.sh")

    File.write!(
      env_file,
      """
      export CASEIN_API_TOKEN='test-token'
      export CASEIN_WORKSPACE_ID='#{workspace_id}'
      export CASEIN_WORKSPACE_NAME='#{workspace_name}'
      #{extra}
      """
    )

    env_file
  end

  defp git_env do
    [
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@t"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@t"}
    ]
  end

  # Healthy headroom for inline dry-run fixtures that do not use preflight_fixture!/2 (#863).
  defp healthy_headroom_env(tmp) do
    loadavg = Path.join(tmp, "loadavg")
    meminfo = Path.join(tmp, "meminfo")
    File.write!(loadavg, "1.00 1.00 1.00 1/100 1\n")

    File.write!(meminfo, """
    MemTotal:       999999999 kB
    MemFree:        40000000 kB
    MemAvailable:   40000000 kB
    """)

    [
      {"CASEIN_SPAWN_LOADAVG_PATH", loadavg},
      {"CASEIN_SPAWN_MEMINFO_PATH", meminfo},
      {"CASEIN_SPAWN_NPROC", "32"},
      {"CASEIN_SPAWN_MAX_LOAD_RATIO", "1.0"},
      {"CASEIN_SPAWN_MIN_MEM_AVAILABLE_KB", "2097152"},
      {"CASEIN_SPAWN_FORCE", "0"}
    ]
  end
end
