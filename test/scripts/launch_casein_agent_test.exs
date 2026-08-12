defmodule Scripts.LaunchCaseinAgentTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/launch-casein-agent.sh", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "managed Grok binds current tmux scope before capability bundle materialization" do
    text = File.read!(@script)

    checkout_at = byte_offset!(text, "agent_env_bind_current_checkout")
    bind_at = byte_offset!(text, "agent_env_bind_current_tmux_session")
    materialize_at = byte_offset!(text, "run_materialize_export\n")

    assert checkout_at < bind_at
    assert bind_at < materialize_at
  end

  test "every runtime binds the launch cwd, not just grok" do
    text = File.read!(@script)

    grok_block =
      text
      |> String.split(~S<if [[ "$RUNTIME" == "grok" ]]; then>, parts: 2)
      |> List.last()
      |> String.split("\nfi\n", parts: 2)
      |> List.first()

    # Gating this on grok meant `cd <worktree> && opencode` came up in the
    # workspace root, because CASEIN_CHECKOUT stayed at the name-derived default.
    refute grok_block =~ "agent_env_bind_current_checkout"

    # And it has to bind before the worktree logic reads CASEIN_CHECKOUT/PWD.
    assert byte_offset!(text, "agent_env_bind_current_checkout") <
             byte_offset!(text, "agent_worktree_ensure ")
  end

  test "binding the launch cwd resolves a linked worktree over an inherited checkout" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "bind-checkout-#{System.unique_integer([:positive])}"
      )

    primary = Path.join(tmp, "primary")
    linked = Path.join(tmp, "linked")
    File.mkdir_p!(primary)
    on_exit(fn -> File.rm_rf(tmp) end)

    git!(["init", "--quiet", "--initial-branch=main", primary])
    git!(["-C", primary, "config", "user.email", "test@example.com"])
    git!(["-C", primary, "config", "user.name", "Test"])
    File.write!(Path.join(primary, "README"), "x")
    git!(["-C", primary, "add", "README"])
    git!(["-C", primary, "commit", "--quiet", "-m", "init"])
    git!(["-C", primary, "worktree", "add", "--quiet", "-b", "linked", linked])

    {output, 0} =
      System.cmd(
        "bash",
        [
          "-c",
          """
          set -euo pipefail
          source "#{Path.expand("../../scripts/lib/agent-env.sh", __DIR__)}"
          cd "#{linked}"
          agent_env_bind_current_checkout
          printf '%s\n' "$CASEIN_CHECKOUT"
          """
        ],
        env: [{"CASEIN_CHECKOUT", "/data/workspaces/some-workspace"}],
        stderr_to_stdout: true
      )

    # The linked worktree the operator launched in wins over the inherited path.
    assert String.trim(output) == realpath!(linked)
  end

  test "current tmux binding replaces stale URL scope exactly" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "grok-tmux-bind-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(tmp, "bin")
    fake_tmux = Path.join(fake_bin, "tmux")
    File.mkdir_p!(fake_bin)

    File.write!(fake_tmux, """
    #!/usr/bin/env bash
    if [[ "${1:-}" == "display-message" ]]; then
      [[ "${3:-}" == "-t" && "${4:-}" == "%42" ]] || exit 65
      printf '%s\n' "${FAKE_TMUX_SESSION:?}"
      exit 0
    fi
    exit 64
    """)

    File.chmod!(fake_tmux, 0o755)
    on_exit(fn -> File.rm_rf(tmp) end)

    current = "casein_workspace-123_u-current"

    {output, 0} =
      System.cmd(
        "bash",
        [
          "-c",
          """
          set -euo pipefail
          source "#{Path.expand("../../scripts/lib/agent-env.sh", __DIR__)}"
          agent_env_bind_current_tmux_session
          printf '%s\n%s\n%s\n' \
            "$CASEIN_TMUX_SESSION" \
            "$CASEIN_TERMINAL_MCP_URL" \
            "$CASEIN_PREVIEW_MCP_URL"
          """
        ],
        env: [
          {"PATH", "#{fake_bin}:#{System.get_env("PATH")}"},
          {"TMUX", "/tmp/fake,1,0"},
          {"TMUX_PANE", "%42"},
          {"FAKE_TMUX_SESSION", current},
          {"CASEIN_WORKSPACE_ID", "workspace-123"},
          {"CASEIN_TMUX_SESSION", "casein_workspace-123_u-stale"},
          {"CASEIN_TERMINAL_MCP_URL",
           "http://127.0.0.1:4000/api/terminals/mcp?workspace_id=wrong&tmux_session=old&keep=1"},
          {"CASEIN_PREVIEW_MCP_URL",
           "https://casein.example/api/preview/mcp?tmux_session=old&workspace_id=wrong"}
        ]
      )

    assert [^current, terminal_url, preview_url] = String.split(output, "\n", trim: true)
    assert_bound_query(terminal_url, current, [{"keep", "1"}])
    assert_bound_query(preview_url, current)
  end

  test "Grok launches install the session bootstrap and Codex launches inject notify" do
    text = File.read!(@script)

    assert text =~ ~S(export CASEIN_AGENT_LAUNCH_CONTEXT="$RUNTIME")
    assert text =~ "grok_install_state_hook"
    assert text =~ "codex_state_notify_args"
    assert text =~ ~S(notify=[\"${script}\"])
    assert text =~ "codex_state_hook_args"
    assert text =~ "PermissionRequest"
    assert text =~ "SubagentStart"
    assert text =~ "CASEIN_AGENT_STATE_HOOKS"
    assert text =~ "agent-hooks/grok-casein-agent-bootstrap.json"
    assert text =~ "grok_prepare_private_leader"
    assert text =~ "grok-leader-runtime.py"
    assert text =~ ~S(metadata="${root_real}/.casein-launcher")
    assert text =~ ~S(native_lock="${root_real}/leader.lock")
    assert text =~ ~S(kill -TERM -- "-${leader_pid}")
    assert text =~ ~S(kill -KILL -- "-${leader_pid}")
    assert text =~ "grok_private_leader_ready"
    assert text =~ "grok_stop_private_leader"
    assert text =~ "grok_quiesce_for_reattach"
    assert text =~ ~S(kill -STOP -- "-${leader_pid}")
    assert text =~ "resume-after-sandbox"
    assert text =~ ~S(expected_signature="v2:${sandbox_profile}:${permission_mode}")
    assert text =~ ~S(CASEIN_GROK_LEADER_REUSED=true)
    assert text =~ ~S(if [[ "$CASEIN_GROK_CAPABILITY_REUSED" != "true" ]])
    assert text =~ "never replace the"
    assert text =~ "grok_configure_capability"
    assert text =~ "grok_issue_capability"
    assert text =~ "/api/agent-capabilities/current"
    assert text =~ "/grok-agent-capabilities"
    assert text =~ "CASEIN_GROK_BUNDLE_DIR"
    assert text =~ "CASEIN_GROK_SANDBOX_PROFILE"
    # The bwrap base is deliberately unconditional — see
    # Casein.Scripts.GrokLockedMcpNoticeTest. The write unlock gates the MCP
    # grant only, so "read-only" must not reappear as a sandbox base here.
    assert text =~ ~S(sandbox_base="strict")
    refute text =~ ~S(sandbox_base="read-only")
    assert text =~ "CASEIN_AGENT_REQUIRE_WRITE"
    assert text =~ "grok_refuse_locked_orchestrator"
    assert text =~ ~S|capability_file="$(dirname "$socket")/capability"|
    assert text =~ ~S(.launch-${grok_leader_id}.flock)
    assert text =~ ~S(flock -w 15 "$grok_launch_fd")
    assert text =~ "grok_prepare_managed_home"
    assert text =~ "grok-managed-home.py"
    assert text =~ ~S(CASEIN_GROK_PROVIDER_AUTH_MODE="api-key")
    assert text =~ ~S(CASEIN_GROK_PROVIDER_AUTH_MODE="oauth-inline-refresh")
    assert text =~ ~S(export GROK_AUTH="$provider_auth")
    assert text =~ ~S("${GROK_HOME}/auth.json")
    assert text =~ "GROK_AUTH_PROVIDER_COMMAND"
    assert text =~ ~S("${HOME}/.grok/auth.json")
    assert text =~ "GROK_SUBAGENTS=0"
    assert text =~ ~S(--leader-socket "$grok_socket" --no-subagents)
    assert text =~ ~S("${HOME}/.ssh")
    assert text =~ "find /data/workspaces -xdev -maxdepth 4"
    assert text =~ ~S("/proc")
    refute text =~ ~S("/proc/*/environ")
    refute text =~ ~S("/data/workspaces/*/.devbox-agent.env")
    refute text =~ ~S("/data/workspaces/*/*/.devbox-agent.env")
    assert text =~ "managed Grok capability materialization failed"
    assert text =~ ~S(unset CASEIN_ADMIN_API_TOKEN CASEIN_WORKSPACE_API_TOKENS)
    assert text =~ ~S(--permission-mode "$CASEIN_GROK_PERMISSION_MODE")
    assert text =~ "--no-auto-update"
    refute text =~ ~S(lock_file="${socket_real%.sock}.lock")
    refute text =~ ~S|leader_pid="$(<"$lock_file")"|
    refute text =~ ~S(leader kill)
  end

  test "pairing env generators do not persist the global admin bearer" do
    setup = File.read!(Path.expand("../../scripts/setup-devbox-agent-pairing.sh", __DIR__))
    refresh = File.read!(Path.expand("../../scripts/refresh-devbox-agent-pairing.sh", __DIR__))

    refute setup =~ "export CASEIN_ADMIN_API_TOKEN="
    refute refresh =~ "export CASEIN_ADMIN_API_TOKEN="
  end

  test "codex defaults to full access, preserves explicit policies, and scrubs bearer credentials" do
    text = File.read!(@script)

    assert text =~ ~S(CASEIN_CODEX_DEFAULT_YOLO:-1)
    assert text =~ "codex_arg_sets_execution_policy"
    assert text =~ ~S(--dangerously-bypass-approvals-and-sandbox)
    assert text =~ "codex_workspace_mode"
    assert text =~ "/api/workspaces/${workspace_id}/status"
    assert text =~ ~S(--sandbox workspace-write --ask-for-approval on-request)
    assert text =~ ~S(--sandbox read-only --ask-for-approval never)
    assert text =~ ~S(shell_environment_policy.exclude)
  end

  test "codex preserves the operator model across isolated owner auth profiles" do
    text = File.read!(@script)

    assert text =~ "codex_model_args"
    assert text =~ "codex_arg_sets_model"
    assert text =~ ~S(CASEIN_CODEX_DEFAULT_MODEL)
    assert text =~ ~S(${HOME}/.codex/config.toml)
    assert text =~ ~S(printf '%s\0' --model "$model")
  end

  # Extracts the real opencode model helpers out of the launcher and runs them,
  # so this asserts behavior rather than the presence of source text.
  # `prefix` is prepended verbatim to the call, so a test can express "set but
  # empty" — which System.cmd's env cannot: Erlang treats an empty value as unset.
  defp opencode_model_args(argv, prefix \\ "") do
    text = File.read!(@script)

    functions =
      ~w(opencode_arg_sets_model opencode_arg_uses_model_capable_command opencode_model_args)
      |> Enum.map_join("\n", &extract_function!(text, &1))

    script = """
    set -euo pipefail
    #{functions}
    #{prefix} opencode_model_args #{Enum.map_join(argv, " ", &"'#{&1}'")}
    """

    {out, 0} = System.cmd("bash", ["-c", script])
    String.split(out, <<0>>, trim: true)
  end

  defp extract_function!(text, name) do
    [_, body] = String.split(text, "\n#{name}() {\n", parts: 2)
    [body, _] = String.split(body, "\n}\n", parts: 2)
    "#{name}() {\n#{body}\n}"
  end

  test "opencode launches pin a default model, since the host-global one is shared" do
    # Default TUI invocation — the one delegation uses.
    assert opencode_model_args([]) == ["--model", "opencode/grok-4.6"]

    # `run` accepts --model; the flag rides ahead of the subcommand.
    assert opencode_model_args(["run", "do x"]) == ["--model", "opencode/grok-4.6"]

    # Overridable per launch.
    assert opencode_model_args([], "CASEIN_OPENCODE_DEFAULT_MODEL=opencode/claude-fable-5") ==
             ["--model", "opencode/claude-fable-5"]

    # Set-but-empty opts out entirely, letting ~/.config/opencode win.
    assert opencode_model_args([], "CASEIN_OPENCODE_DEFAULT_MODEL=") == []
  end

  test "opencode model injection yields to an explicit flag and to subcommands that reject it" do
    # An operator's own choice always wins.
    assert opencode_model_args(["--model", "xai/grok-4.5"]) == []
    assert opencode_model_args(["-m", "xai/grok-4.5"]) == []

    # `opencode --model X models` abandons the command and prints usage, so these
    # subcommands must never receive the injected flag.
    assert opencode_model_args(["models"]) == []
    assert opencode_model_args(["serve"]) == []
    assert opencode_model_args(["export"]) == []
  end

  test "managed Codex tabs prefer the thread title while allowing an explicit override" do
    text = File.read!(@script)

    assert text =~ "codex_terminal_title_args"
    assert text =~ "codex_arg_sets_terminal_title"
    assert text =~ ~S(tui.terminal_title=["spinner","thread"])
    assert text =~ ~S(tui.terminal_title=*)
  end

  test "claude launches stage Casein-infra skills into the resolved config home" do
    text = File.read!(@script)

    assert text =~ "lib/agent-skills.sh"
    assert text =~ ~S(agent_skills_install "${ROOT}/.claude/skills")
    # Must target the owner profile's config dir when set, else host global ~/.claude.
    assert text =~ ~S(${CLAUDE_CONFIG_DIR:-${HOME}/.claude})
  end

  test "codex stages Casein skills and supports a read-only sidechat" do
    text = File.read!(@script)

    assert text =~
             ~S(agent_skills_install "${ROOT}/.claude/skills" "${CODEX_HOME:-${HOME}/.codex}")

    assert text =~ "codex-sidechat-prompt.txt"
    assert text =~ "developer_instructions="
    assert text =~ "--sandbox read-only --ask-for-approval never"
  end

  test "codex MCP overrides use unquoted server keys" do
    text = File.read!(@script)

    refute text =~ "mcp_servers.\\\""
    assert text =~ "mcp_servers.${terminal_key}.url"
    assert text =~ "mcp_servers.${terminal_key}.bearer_token_env_var"
    assert text =~ "mcp_servers.${preview_key}.url"
    assert text =~ "mcp_servers.${preview_key}.bearer_token_env_var"
    assert text =~ "mcp_servers.${artifact_key}.url"
    assert text =~ "mcp_servers.${artifact_key}.bearer_token_env_var"
    assert text =~ "mcp_servers.${tidewave_key}.url"
  end

  test "a renamed tmux socket is rebound instead of failing the launch" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "grok-tmux-socket-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(tmp, "bin")
    socket_dir = Path.join([tmp, "run", "tmux-#{uid()}"])
    good_socket = Path.join(socket_dir, "casein")
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(socket_dir)
    on_exit(fn -> File.rm_rf(tmp) end)

    # -S accepts a path only if it is a real socket file, so bind one.
    {_, 0} =
      System.cmd("python3", [
        "-c",
        "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])",
        good_socket
      ])

    fake_tmux = Path.join(fake_bin, "tmux")

    # Stands in for a server whose socket file was renamed underneath it: the
    # path baked into the inherited $TMUX is dead, only the new path answers.
    File.write!(fake_tmux, """
    #!/usr/bin/env bash
    # Same socket resolution as real tmux: -S wins, else the path in $TMUX.
    sock="${TMUX%%,*}"
    if [[ "${1:-}" == "-S" ]]; then
      sock="$2"
      shift 2
    fi
    if [[ "$sock" != "${FAKE_TMUX_GOOD_SOCKET:?}" ]]; then
      echo "no server running on ${sock}" >&2
      exit 1
    fi
    [[ "${1:-}" == "display-message" ]] || exit 64
    shift
    args=("$@")
    if [[ "${args[1]:-}" == "-t" ]]; then
      [[ "${args[2]:-}" == "%42" ]] || exit 65
    fi
    case "${args[-1]}" in
      '\#{session_name}') printf '%s\\n' "${FAKE_TMUX_SESSION:?}" ;;
      '\#{session_id}') printf '$7\\n' ;;
      '\#{pid}') printf '4242\\n' ;;
      *) exit 64 ;;
    esac
    """)

    File.chmod!(fake_tmux, 0o755)

    current = "casein_workspace-123_u-current"

    {output, 0} =
      System.cmd(
        "bash",
        [
          "-c",
          """
          set -euo pipefail
          source "#{Path.expand("../../scripts/lib/agent-env.sh", __DIR__)}"
          agent_env_bind_current_tmux_session
          printf '%s\\n%s\\n%s\\n' "$TMUX" "$CASEIN_TMUX_SESSION" "$CASEIN_TERMINAL_MCP_URL"
          """
        ],
        stderr_to_stdout: false,
        env: [
          {"PATH", "#{fake_bin}:#{System.get_env("PATH")}"},
          {"TMUX", "#{Path.join(socket_dir, "devide")},1,0"},
          {"TMUX_PANE", "%42"},
          {"TMUX_TMPDIR", Path.join(tmp, "run")},
          {"FAKE_TMUX_GOOD_SOCKET", good_socket},
          {"FAKE_TMUX_SESSION", current},
          {"CASEIN_TMUX_SESSION", current},
          {"CASEIN_WORKSPACE_ID", "workspace-123"},
          {"CASEIN_TERMINAL_MCP_URL", "http://127.0.0.1:4000/api/terminals/mcp"},
          {"CASEIN_PREVIEW_MCP_URL", "http://127.0.0.1:4000/api/preview/mcp"}
        ]
      )

    assert [tmux, ^current, terminal_url] = String.split(output, "\n", trim: true)

    # $TMUX itself is repaired, so every later bare `tmux` call in the launch
    # (state hooks, repair-tmux-env.sh, the agent CLI) reaches the live server.
    assert tmux == "#{good_socket},4242,7"
    assert_bound_query(terminal_url, current)
  end

  defp uid do
    {out, 0} = System.cmd("id", ["-u"])
    String.trim(out)
  end

  defp assert_bound_query(url, session, extra \\ []) do
    query =
      url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.query_decoder()
      |> Enum.to_list()

    assert Enum.count(query, &match?({"workspace_id", _}, &1)) == 1
    assert Enum.count(query, &match?({"tmux_session", _}, &1)) == 1
    assert {"workspace_id", "workspace-123"} in query
    assert {"tmux_session", session} in query

    Enum.each(extra, fn pair -> assert pair in query end)
  end

  defp git!(args) do
    {_, 0} = System.cmd("git", args, stderr_to_stdout: true)
    :ok
  end

  defp realpath!(path) do
    {out, 0} = System.cmd("realpath", ["-m", path])
    String.trim(out)
  end

  defp byte_offset!(text, needle) do
    {offset, _length} = :binary.match(text, needle)
    offset
  end
end
