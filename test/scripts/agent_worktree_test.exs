defmodule Scripts.AgentWorktreeTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/lib/agent-worktree.sh")

  test "agent_worktree_create emits one line and creates a branch worktree" do
    %{repo: repo, root: worktree_root} = git_fixture!()

    {path, 0} =
      bash_agent_worktree(
        """
        agent_worktree_create codex pin
        """,
        env: [
          {"DEVIDE_CHECKOUT", repo},
          {"DEVIDE_AGENT_WORKTREE_ROOT", worktree_root},
          {"DEVIDE_AGENT_WORKTREE_BASE", "HEAD"}
        ]
      )

    lines = String.split(path, "\n", trim: true)
    assert [worktree_path] = lines
    assert File.dir?(worktree_path)
    assert Path.dirname(worktree_path) == worktree_root
    assert Path.basename(worktree_path) =~ ~r/^agent-codex-pin-\d{14}$/

    {branch, 0} = System.cmd("git", ["-C", worktree_path, "rev-parse", "--abbrev-ref", "HEAD"])
    assert String.starts_with?(String.trim(branch), "agent/codex/pin-")
    refute String.trim(branch) == "HEAD"
  end

  test "agent_worktree_create defaults to origin HEAD when the remote uses main" do
    %{repo: repo, root: worktree_root} = git_fixture!()

    git!(["-C", repo, "branch", "-m", "main"])

    remote = Path.join(Path.dirname(repo), "remote.git")
    git!(["init", "--bare", "--initial-branch=main", remote])
    git!(["-C", repo, "remote", "add", "origin", remote])
    git!(["-C", repo, "push", "-u", "origin", "main"])
    git!(["-C", repo, "remote", "set-head", "origin", "-a"])

    {path, 0} =
      bash_agent_worktree(
        """
        agent_worktree_create codex mainrepo
        """,
        env: [
          {"DEVIDE_CHECKOUT", repo},
          {"DEVIDE_AGENT_WORKTREE_ROOT", worktree_root}
        ]
      )

    worktree_path = String.trim(path)
    assert File.dir?(worktree_path)

    {branch, 0} = System.cmd("git", ["-C", worktree_path, "rev-parse", "--abbrev-ref", "HEAD"])
    assert String.starts_with?(String.trim(branch), "agent/codex/mainrepo-")

    {merge_base, 0} =
      System.cmd("git", ["-C", worktree_path, "merge-base", "HEAD", "origin/main"])

    {origin_main, 0} = System.cmd("git", ["-C", worktree_path, "rev-parse", "origin/main"])
    assert String.trim(merge_base) == String.trim(origin_main)
  end

  test "agent_worktree_ensure with FORCE_FRESH branches a new worktree instead of adopting a linked one" do
    %{repo: repo, root: worktree_root} = git_fixture!()
    # Simulate the orchestrator's own linked worktree that a spawned worker
    # would otherwise land in and adopt.
    linked = Path.join(Path.dirname(repo), "orchestrator-linked")
    git!(["-C", repo, "worktree", "add", "-b", "orchestrator", linked, "master"])

    {out, 0} =
      bash_agent_worktree(
        """
        agent_worktree_report_mcp() { :; }
        agent_worktree_spawn_reaper() { :; }
        cd "#{linked}"
        agent_worktree_ensure grok freshtest
        printf 'RESULT=%s\\n' "$DEVIDE_CHECKOUT"
        """,
        env: [
          {"DEVIDE_CHECKOUT", repo},
          {"DEVIDE_AGENT_WORKTREE_ROOT", worktree_root},
          {"DEVIDE_AGENT_WORKTREE_BASE", "HEAD"},
          {"DEVIDE_AGENT_FORCE_FRESH_WORKTREE", "1"}
        ]
      )

    [result] = Regex.run(~r/RESULT=(.+)/, out, capture: :all_but_first)
    # A fresh worktree under the worktree root — NOT the adopted linked tree.
    assert Path.dirname(result) == worktree_root
    assert Path.basename(result) =~ ~r/^agent-grok-freshtest-\d{14}$/
    refute result == linked
  end

  test "agent_worktree_ensure WITHOUT force-fresh still adopts a linked worktree" do
    %{repo: repo, root: worktree_root} = git_fixture!()
    linked = Path.join(Path.dirname(repo), "orchestrator-linked")
    git!(["-C", repo, "worktree", "add", "-b", "orchestrator", linked, "master"])

    {out, 0} =
      bash_agent_worktree(
        """
        agent_worktree_report_mcp() { :; }
        agent_worktree_spawn_reaper() { :; }
        cd "#{linked}"
        agent_worktree_ensure grok adopttest
        printf 'RESULT=%s\\n' "$DEVIDE_CHECKOUT"
        """,
        env: [
          {"DEVIDE_CHECKOUT", repo},
          {"DEVIDE_AGENT_WORKTREE_ROOT", worktree_root},
          {"DEVIDE_AGENT_WORKTREE_BASE", "HEAD"}
        ]
      )

    [result] = Regex.run(~r/RESULT=(.+)/, out, capture: :all_but_first)
    # Legacy path: a human inside an existing worktree reuses it.
    assert result == linked
  end

  test "agent_worktree_report_mcp sends a tools/call envelope" do
    %{repo: repo} = git_fixture!()
    curl_bin = fake_curl_bin!()
    body_path = Path.join(Path.dirname(curl_bin), "body.json")

    {stderr, 0} =
      bash_agent_worktree(
        """
        agent_worktree_report_mcp "$DEVIDE_CHECKOUT" codex
        """,
        env: [
          {"DEVIDE_CHECKOUT", repo},
          {"ROOT", @root},
          {"PATH", "#{Path.dirname(curl_bin)}:#{system_path()}"},
          {"FAKE_CURL_BODY", body_path},
          {"CASEIN_API_TOKEN", "scoped-token"},
          {"DEVIDE_WORKSPACE_ID", "workspace-123"},
          {"DEVIDE_TMUX_SESSION", "devide_workspace-123_u-agent"},
          {"DEVIDE_TERMINAL_MCP_URL", "http://127.0.0.1:4000/api/terminals/mcp"}
        ],
        stderr_to_stdout: true
      )

    assert stderr =~ "reported worktree"

    body = body_path |> File.read!() |> Jason.decode!()
    assert body["jsonrpc"] == "2.0"
    assert body["method"] == "tools/call"

    params = body["params"]
    assert params["name"] == "terminal_report_worktree"

    args = params["arguments"]
    assert args["workspace_id"] == "workspace-123"
    assert args["worktree_path"] == repo
    assert args["branch"] == "master"
    assert args["agent"] == "codex"
    assert args["tmux_session_id"] == "devide_workspace-123_u-agent"
  end

  test "launcher keeps materialize and tmux repair failures visible" do
    %{launcher: launcher, home: home} = launcher_fixture!()

    {output, 0} =
      System.cmd(
        "bash",
        [launcher, "agent"],
        env: [
          {"HOME", home},
          {"PATH", system_path()},
          {"CASEIN_API_TOKEN", "scoped-token"},
          {"DEVIDE_WORKSPACE_ID", "workspace-123"},
          {"DEVIDE_WORKSPACE_NAME", "workspace-123"},
          {"DEVIDE_TERMINAL_MCP_URL", "http://127.0.0.1:4000/api/terminals/mcp"},
          {"DEVIDE_PREVIEW_MCP_URL", "http://127.0.0.1:4000/api/preview/mcp"},
          {"DEVIDE_TMUX_SESSION", "devide_workspace-123_u-agent"},
          {"DEVIDE_AGENT_SKIP_WORKTREE", "1"}
        ],
        stderr_to_stdout: true
      )

    assert output =~ "warn: materialize-agent-mcp.sh --export failed"
    assert output =~ "materialize stderr body"
    assert output =~ "stdout; redacted because it may contain tokens"
    refute output =~ "leaked-token"
    assert output =~ "warn: repair-tmux-env.sh failed"
    assert output =~ "repair stderr body"
    assert output =~ "repair stdout body"
    assert output =~ "fake agent reached"
  end

  test "real agent resolver prefers user npm Codex over stale recorded system install" do
    tmp = tmp_dir!("real-agent-bin-test")
    home = Path.join(tmp, "home")
    npm_prefix = Path.join(home, ".local/share/npm-global")
    user_codex = Path.join(npm_prefix, "lib/node_modules/@openai/codex/bin/codex.js")
    stale_codex = Path.join(tmp, "usr/lib/node_modules/@openai/codex/bin/codex.js")
    real_bins = Path.join(home, ".casein/real-bins")

    File.mkdir_p!(Path.dirname(user_codex))
    File.mkdir_p!(Path.dirname(stale_codex))
    File.mkdir_p!(real_bins)
    File.write!(user_codex, "#!/usr/bin/env bash\n")
    File.write!(stale_codex, "#!/usr/bin/env bash\n")
    File.ln_s!(stale_codex, Path.join(real_bins, "codex"))

    {resolved, 0} =
      System.cmd(
        "bash",
        [
          "-c",
          """
          set -euo pipefail
          source "#{@root}/scripts/lib/real-agent-bin.sh"
          real_agent_bin codex
          """
        ],
        env: [
          {"HOME", home},
          {"CASEIN_NPM_PREFIX", npm_prefix},
          {"PATH", "#{Path.dirname(stale_codex)}:#{system_path()}"}
        ]
      )

    assert String.trim(resolved) == user_codex
  end

  test "install-agent-shims keeps npm prefix separate and records npm Codex" do
    tmp = tmp_dir!("install-agent-shims-test")
    home = Path.join(tmp, "home")
    npm_prefix = Path.join(home, ".local/share/npm-global")
    fake_bin = Path.join(tmp, "bin")
    fake_npm = Path.join(fake_bin, "npm")
    npm_set = Path.join(tmp, "npm-prefix-set")
    user_codex = Path.join(npm_prefix, "lib/node_modules/@openai/codex/bin/codex.js")
    system_codex_dir = Path.join(tmp, "system-bin")
    system_codex = Path.join(system_codex_dir, "codex")

    File.mkdir_p!(Path.dirname(user_codex))
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(system_codex_dir)
    File.write!(user_codex, "#!/usr/bin/env bash\n")
    File.write!(system_codex, "#!/usr/bin/env bash\n")
    File.chmod!(system_codex, 0o755)

    File.write!(fake_npm, """
    #!/usr/bin/env bash
    set -euo pipefail
    case "${1:-} ${2:-} ${3:-}" in
      "config get prefix")
        printf '%s\\n' "${HOME}/.local"
        ;;
      "config set prefix")
        printf '%s\\n' "${4:?}" >"${FAKE_NPM_SET:?}"
        ;;
      *)
        exit 64
        ;;
    esac
    """)

    File.chmod!(fake_npm, 0o755)

    {output, 0} =
      System.cmd(
        "bash",
        [Path.join(@root, "scripts/install-agent-shims.sh")],
        env: [
          {"HOME", home},
          {"CASEIN_NPM_PREFIX", npm_prefix},
          {"FAKE_NPM_SET", npm_set},
          {"CASEIN_MANAGE_NPM_PREFIX", "1"},
          {"PATH", "#{fake_bin}:#{system_codex_dir}:#{system_path()}"}
        ],
        stderr_to_stdout: true
      )

    assert output =~ "Installed Casein agent shims"
    assert File.read!(npm_set) == npm_prefix <> "\n"
    assert File.read_link!(Path.join(home, ".casein/real-bins/codex")) == user_codex

    assert File.read!(Path.join(home, ".casein/agent-shims/codex")) =~
             "devide\" agent launch codex"
  end

  test "devide shim passes codex update directly to the real CLI" do
    tmp = tmp_dir!("devide-codex-update-test")
    home = Path.join(tmp, "home")
    npm_prefix = Path.join(home, ".local/share/npm-global")

    fake_codex =
      Path.join(npm_prefix, "lib/node_modules/@openai/codex/bin/codex.js")

    fake_bin = Path.join(tmp, "bin")
    fake_npm = Path.join(fake_bin, "npm")
    npm_set = Path.join(tmp, "npm-prefix-set")

    File.mkdir_p!(Path.dirname(fake_codex))
    File.mkdir_p!(fake_bin)

    File.write!(fake_codex, """
    #!/usr/bin/env bash
    printf 'fake codex'
    for arg in "$@"; do
      printf ' <%s>' "$arg"
    done
    printf '\\n'
    """)

    File.chmod!(fake_codex, 0o755)

    File.write!(fake_npm, """
    #!/usr/bin/env bash
    set -euo pipefail
    case "${1:-} ${2:-} ${3:-}" in
      "config get prefix")
        printf '%s\\n' "${HOME}/.local"
        ;;
      "config set prefix")
        printf '%s\\n' "${4:?}" >"${FAKE_NPM_SET:?}"
        exit 0
        ;;
      *)
        exit 64
        ;;
    esac
    """)

    File.chmod!(fake_npm, 0o755)

    {output, 0} =
      System.cmd(
        "bash",
        [Path.join(@root, "scripts/devide"), "agent", "launch", "codex", "update"],
        env: [
          {"HOME", home},
          {"CASEIN_NPM_PREFIX", npm_prefix},
          {"FAKE_NPM_SET", npm_set},
          {"CASEIN_MANAGE_NPM_PREFIX", "1"},
          {"PATH", "#{fake_bin}:/usr/bin:/bin"}
        ],
        stderr_to_stdout: true
      )

    assert output =~ "fake codex <update>\n"
    assert output =~ "Installed Casein agent shims"
    assert File.read!(npm_set) == npm_prefix <> "\n"

    assert File.read!(Path.join(home, ".casein/agent-shims/codex")) =~
             "devide\" agent launch codex"
  end

  test "installed devide CLI does not route launches through a stale paired scripts tree" do
    tmp = tmp_dir!("devide-launch-revision-test")
    root = Path.join(tmp, "installed")
    scripts = Path.join(root, "scripts")
    lib = Path.join(scripts, "lib")
    stale_scripts = Path.join(tmp, "stale-checkout/scripts")

    File.mkdir_p!(lib)
    File.mkdir_p!(stale_scripts)
    File.cp!(Path.join(@root, "scripts/devide"), Path.join(scripts, "devide"))

    for file <- ["agent-env.sh", "real-agent-bin.sh"] do
      File.ln_s!(Path.join(@root, "scripts/lib/#{file}"), Path.join(lib, file))
    end

    File.write!(Path.join(scripts, "launch-casein-agent.sh"), """
    #!/usr/bin/env bash
    printf 'installed launcher <%s>\n' "$1"
    """)

    File.write!(Path.join(stale_scripts, "launch-casein-agent.sh"), """
    #!/usr/bin/env bash
    printf 'stale launcher <%s>\n' "$1"
    """)

    {output, 0} =
      System.cmd(
        "bash",
        [Path.join(scripts, "devide"), "agent", "launch", "grok"],
        env: [
          {"HOME", Path.join(tmp, "home")},
          {"PATH", system_path()},
          {"CASEIN_API_TOKEN", "scoped-token"},
          {"DEVIDE_WORKSPACE_ID", "workspace-123"},
          {"DEVIDE_WORKSPACE_NAME", "workspace-123"},
          {"DEVIDE_SCRIPTS", stale_scripts}
        ],
        stderr_to_stdout: true
      )

    assert output == "installed launcher <grok>\n"
    refute output =~ "stale launcher"
  end

  defp git_fixture! do
    tmp =
      Path.join(System.tmp_dir!(), "agent-worktree-test-#{System.unique_integer([:positive])}")

    repo = Path.join(tmp, "repo")
    worktree_root = Path.join(tmp, "worktrees")
    File.mkdir_p!(repo)

    git!(["init", "--initial-branch=master", repo])
    git!(["-C", repo, "config", "user.email", "devide@example.invalid"])
    git!(["-C", repo, "config", "user.name", "Casein Test"])
    File.write!(Path.join(repo, "README.md"), "test\n")
    git!(["-C", repo, "add", "README.md"])
    git!(["-C", repo, "commit", "-m", "init"])

    on_exit(fn -> File.rm_rf(tmp) end)

    %{repo: repo, root: worktree_root}
  end

  defp fake_curl_bin! do
    tmp =
      Path.join(System.tmp_dir!(), "agent-worktree-curl-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    path = Path.join(tmp, "curl")

    File.write!(path, """
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ "$*" == *"--max-time 2"* ]]; then
      printf '200'
      exit 0
    fi

    body=""
    previous=""
    for arg in "$@"; do
      if [[ "$previous" == "-d" ]]; then
        body="$arg"
        break
      fi
      previous="$arg"
    done

    printf '%s' "$body" >"${FAKE_CURL_BODY:?}"
    printf '{"jsonrpc":"2.0","id":1,"result":{"content":[]}}\\n'
    """)

    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(tmp) end)

    path
  end

  defp launcher_fixture! do
    tmp =
      Path.join(System.tmp_dir!(), "agent-launcher-test-#{System.unique_integer([:positive])}")

    root = Path.join(tmp, "root")
    scripts = Path.join(root, "scripts")
    lib = Path.join(scripts, "lib")
    home = Path.join(tmp, "home")
    real_bins = Path.join(home, ".casein/real-bins")

    File.mkdir_p!(lib)
    File.mkdir_p!(real_bins)

    File.ln_s!(
      Path.join(@root, "scripts/launch-casein-agent.sh"),
      Path.join(scripts, "launch-casein-agent.sh")
    )

    for file <- [
          "agent-env.sh",
          "agent-worktree.sh",
          "real-agent-bin.sh",
          "agent-auth-profile.sh",
          "sidechat.sh",
          "agent-skills.sh"
        ] do
      File.ln_s!(Path.join(@root, "scripts/lib/#{file}"), Path.join(lib, file))
    end

    File.write!(Path.join(lib, "merge-agent-mcp.py"), "")

    File.write!(Path.join(scripts, "materialize-agent-mcp.sh"), """
    #!/usr/bin/env bash
    printf 'export CASEIN_API_TOKEN=leaked-token\\n'
    printf 'materialize stderr body\\n' >&2
    exit 42
    """)

    File.write!(Path.join(lib, "repair-tmux-env.sh"), """
    #!/usr/bin/env bash
    printf 'repair stdout body\\n'
    printf 'repair stderr body\\n' >&2
    exit 43
    """)

    fake_agent = Path.join(real_bins, "agent")

    File.write!(fake_agent, """
    #!/usr/bin/env bash
    printf 'fake agent reached\\n'
    """)

    File.chmod!(fake_agent, 0o755)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{launcher: Path.join(scripts, "launch-casein-agent.sh"), home: home}
  end

  defp tmp_dir!(prefix) do
    tmp = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    tmp
  end

  defp bash_agent_worktree(script, opts) do
    # Clear ambient agent-session worktree knobs so a human running the suite
    # from an already-linked agent worktree does not make ensure() adopt *that*
    # path instead of the fixture worktree under test.
    env =
      opts
      |> Keyword.get(:env, [])
      |> then(fn env ->
        [
          {"DEVIDE_AGENT_WORKTREE_PATH", ""},
          {"DEVIDE_AGENT_FORCE_FRESH_WORKTREE", "0"},
          {"DEVIDE_AGENT_SKIP_WORKTREE", "0"}
          | env
        ]
      end)

    stderr_to_stdout = Keyword.get(opts, :stderr_to_stdout, false)

    System.cmd(
      "bash",
      [
        "-c",
        """
        set -euo pipefail
        source "#{@script}"
        #{script}
        """
      ],
      env: env,
      stderr_to_stdout: stderr_to_stdout
    )
  end

  defp system_path do
    System.get_env("PATH") || "/usr/bin:/bin"
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}:\n#{output}")
    end
  end
end
