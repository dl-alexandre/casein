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
          {"DEV_IDE_API_TOKEN", "scoped-token"},
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
          {"DEV_IDE_API_TOKEN", "scoped-token"},
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

  defp git_fixture! do
    tmp =
      Path.join(System.tmp_dir!(), "agent-worktree-test-#{System.unique_integer([:positive])}")

    repo = Path.join(tmp, "repo")
    worktree_root = Path.join(tmp, "worktrees")
    File.mkdir_p!(repo)

    git!(["init", "--initial-branch=master", repo])
    git!(["-C", repo, "config", "user.email", "devide@example.invalid"])
    git!(["-C", repo, "config", "user.name", "DevIDE Test"])
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
    real_bins = Path.join(home, ".devide/real-bins")

    File.mkdir_p!(lib)
    File.mkdir_p!(real_bins)

    File.ln_s!(
      Path.join(@root, "scripts/launch-devide-agent.sh"),
      Path.join(scripts, "launch-devide-agent.sh")
    )

    for file <- [
          "agent-env.sh",
          "agent-worktree.sh",
          "real-agent-bin.sh",
          "agent-auth-profile.sh",
          "sidechat.sh"
        ] do
      File.ln_s!(Path.join(@root, "scripts/lib/#{file}"), Path.join(lib, file))
    end

    File.write!(Path.join(lib, "merge-agent-mcp.py"), "")

    File.write!(Path.join(scripts, "materialize-agent-mcp.sh"), """
    #!/usr/bin/env bash
    printf 'export DEV_IDE_API_TOKEN=leaked-token\\n'
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

    %{launcher: Path.join(scripts, "launch-devide-agent.sh"), home: home}
  end

  defp bash_agent_worktree(script, opts) do
    env = Keyword.get(opts, :env, [])
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
