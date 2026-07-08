defmodule Scripts.LaunchDevideAgentTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/launch-devide-agent.sh", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "grok launches install the global state hook and codex launches inject notify" do
    text = File.read!(@script)

    assert text =~ "grok_install_state_hook"
    assert text =~ "codex_state_notify_args"
    assert text =~ ~S(notify=[\"${script}\"])
    assert text =~ "DEVIDE_AGENT_STATE_HOOKS"
    assert text =~ "agent-hooks/grok-devide-agent-state.json"
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
