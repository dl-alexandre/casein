defmodule Scripts.LaunchDevideAgentTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/launch-devide-agent.sh", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
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
