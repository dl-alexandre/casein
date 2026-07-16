defmodule Scripts.LaunchDevideAgentTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/launch-devide-agent.sh", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
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
    assert text =~ "grok_configure_capability"
    assert text =~ "grok_issue_capability"
    assert text =~ "/api/agent-capabilities/current"
    assert text =~ "/grok-agent-capabilities"
    assert text =~ "DEVIDE_GROK_BUNDLE_DIR"
    assert text =~ "DEVIDE_GROK_SANDBOX_PROFILE"
    assert text =~ ~S(sandbox_base="strict")
    assert text =~ ~S(sandbox_base="read-only")
    assert text =~ "*.capability"
    assert text =~ ~S("${HOME}/.ssh")
    assert text =~ "managed Grok capability materialization failed"
    assert text =~ ~S(unset DEV_IDE_ADMIN_API_TOKEN DEV_IDE_WORKSPACE_API_TOKENS)
    assert text =~ ~S(--permission-mode "$DEVIDE_GROK_PERMISSION_MODE")
    assert text =~ "--no-auto-update"
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
end
