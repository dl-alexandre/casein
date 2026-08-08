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

    # Stub tmux: `has-session` succeeds, `new-window` hands back a pane id,
    # `list-panes` reports whatever liveness FAKE_PANE_STATE asks for, and
    # `display-message` hands back the pane's root pid so the readiness walk has
    # somewhere to start. Window disposal is journalled for assertions.
    File.write!(Path.join(fakebin, "tmux"), """
    #!/usr/bin/env bash
    case "${1:-}" in
      list-panes)
        case "${FAKE_PANE_STATE:-alive}" in
          alive) printf '%%99 0\\n' ;;
          dead) printf '%%99 1\\n' ;;
          gone) : ;;
        esac
        ;;
      new-window) printf '%%99\\n' ;;
      display-message) printf '424242\\n' ;;
      kill-window | rename-window)
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

    %{
      product: product,
      fakebin: fakebin,
      env_file: env_file,
      tmux_log: Path.join(tmp, "tmux-calls.log")
    }
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

  # Non-dry-run: exercises the real new-window + probe + readiness path against
  # stub tmux. Both budgets are trimmed so the passing cases do not idle for the
  # full production windows.
  defp spawn_worker(ctx, runtime, extra_env) do
    System.cmd("bash", [@script, runtime, "iso", "casein_test_u-x"],
      env:
        [
          {"CASEIN_CHECKOUT", ctx.product},
          {"CASEIN_API_TOKEN", "test-token"},
          {"CASEIN_WORKSPACE_ID", "test-ws"},
          {"CASEIN_API_BASE_URL", "http://127.0.0.1:4000"},
          {"CASEIN_AGENT_ENV_FILE", ctx.env_file},
          {"CASEIN_SPAWN_PROBE_SECONDS", "1"},
          {"CASEIN_SPAWN_READY_SECONDS", "2"},
          {"FAKE_TMUX_LOG", ctx.tmux_log},
          {"PATH", ctx.fakebin <> ":" <> System.get_env("PATH")}
        ] ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp tmux_calls(ctx) do
    case File.read(ctx.tmux_log) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
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
