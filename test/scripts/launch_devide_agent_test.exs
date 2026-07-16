defmodule Scripts.LaunchDevideAgentTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/launch-devide-agent.sh", __DIR__)

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

    current = "devide_workspace-123_u-current"

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
            "$DEVIDE_TMUX_SESSION" \
            "$DEVIDE_TERMINAL_MCP_URL" \
            "$DEVIDE_PREVIEW_MCP_URL"
          """
        ],
        env: [
          {"PATH", "#{fake_bin}:#{System.get_env("PATH")}"},
          {"TMUX", "/tmp/fake,1,0"},
          {"TMUX_PANE", "%42"},
          {"FAKE_TMUX_SESSION", current},
          {"DEVIDE_WORKSPACE_ID", "workspace-123"},
          {"DEVIDE_TMUX_SESSION", "devide_workspace-123_u-stale"},
          {"DEVIDE_TERMINAL_MCP_URL",
           "http://127.0.0.1:4000/api/terminals/mcp?workspace_id=wrong&tmux_session=old&keep=1"},
          {"DEVIDE_PREVIEW_MCP_URL",
           "https://devide.example/api/preview/mcp?tmux_session=old&workspace_id=wrong"}
        ]
      )

    assert [^current, terminal_url, preview_url] = String.split(output, "\n", trim: true)
    assert_bound_query(terminal_url, current, [{"keep", "1"}])
    assert_bound_query(preview_url, current)
  end

  test "Grok launches install the session bootstrap and Codex launches inject notify" do
    text = File.read!(@script)

    assert text =~ ~S(export DEVIDE_AGENT_LAUNCH_CONTEXT="$RUNTIME")
    assert text =~ "grok_install_state_hook"
    assert text =~ "codex_state_notify_args"
    assert text =~ ~S(notify=[\"${script}\"])
    assert text =~ "DEVIDE_AGENT_STATE_HOOKS"
    assert text =~ "agent-hooks/grok-devide-agent-bootstrap.json"
    assert text =~ "grok_prepare_private_leader"
    assert text =~ "grok-leader-runtime.py"
    assert text =~ ~S(metadata="${root_real}/.devide-launcher")
    assert text =~ ~S(native_lock="${root_real}/leader.lock")
    assert text =~ ~S(kill -TERM -- "-${leader_pid}")
    assert text =~ ~S(kill -KILL -- "-${leader_pid}")
    assert text =~ "grok_private_leader_ready"
    assert text =~ "grok_stop_private_leader"
    assert text =~ "grok_quiesce_for_reattach"
    assert text =~ ~S(kill -STOP -- "-${leader_pid}")
    assert text =~ "resume-after-sandbox"
    assert text =~ ~S(expected_signature="v2:${sandbox_profile}:${permission_mode}")
    assert text =~ ~S(DEVIDE_GROK_LEADER_REUSED=true)
    assert text =~ ~S(if [[ "$DEVIDE_GROK_CAPABILITY_REUSED" != "true" ]])
    assert text =~ "never replace the"
    assert text =~ "grok_configure_capability"
    assert text =~ "grok_issue_capability"
    assert text =~ "/api/agent-capabilities/current"
    assert text =~ "/grok-agent-capabilities"
    assert text =~ "DEVIDE_GROK_BUNDLE_DIR"
    assert text =~ "DEVIDE_GROK_SANDBOX_PROFILE"
    assert text =~ ~S(sandbox_base="strict")
    assert text =~ ~S(sandbox_base="read-only")
    assert text =~ ~S|capability_file="$(dirname "$socket")/capability"|
    assert text =~ ~S(.launch-${grok_leader_id}.flock)
    assert text =~ ~S(flock -w 15 "$grok_launch_fd")
    assert text =~ "grok_prepare_managed_home"
    assert text =~ "grok-managed-home.py"
    assert text =~ ~S(DEVIDE_GROK_PROVIDER_AUTH_MODE="api-key")
    assert text =~ ~S(DEVIDE_GROK_PROVIDER_AUTH_MODE="oauth-inline-refresh")
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
    assert text =~ ~S(unset DEV_IDE_ADMIN_API_TOKEN DEV_IDE_WORKSPACE_API_TOKENS)
    assert text =~ ~S(--permission-mode "$DEVIDE_GROK_PERMISSION_MODE")
    assert text =~ "--no-auto-update"
    refute text =~ ~S(lock_file="${socket_real%.sock}.lock")
    refute text =~ ~S|leader_pid="$(<"$lock_file")"|
    refute text =~ ~S(leader kill)
  end

  test "pairing env generators do not persist the global admin bearer" do
    setup = File.read!(Path.expand("../../scripts/setup-devbox-agent-pairing.sh", __DIR__))
    refresh = File.read!(Path.expand("../../scripts/refresh-devbox-agent-pairing.sh", __DIR__))

    refute setup =~ "export DEV_IDE_ADMIN_API_TOKEN="
    refute refresh =~ "export DEV_IDE_ADMIN_API_TOKEN="
  end

  test "claude launches stage DevIDE-infra skills into the resolved config home" do
    text = File.read!(@script)

    assert text =~ "lib/agent-skills.sh"
    assert text =~ ~S(agent_skills_install "${ROOT}/.claude/skills")
    # Must target the owner profile's config dir when set, else host global ~/.claude.
    assert text =~ ~S(${CLAUDE_CONFIG_DIR:-${HOME}/.claude})
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

  defp byte_offset!(text, needle) do
    {offset, _length} = :binary.match(text, needle)
    offset
  end
end
