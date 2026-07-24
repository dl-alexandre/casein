defmodule Scripts.MergeAgentMcpTest do
  use ExUnit.Case, async: true

  # The grok `[ui].theme` line is owned by Casein.Terminals.ToolThemes now, so
  # this script only strips stale devide-* MCP blocks and must leave the theme
  # (and all other config) untouched.
  @script Path.expand("../../scripts/lib/merge-agent-mcp.py", __DIR__)

  @base_env [
    {"DEVIDE_TERMINAL_MCP_URL", "http://127.0.0.1:4000/api/terminals/mcp"},
    {"DEVIDE_PREVIEW_MCP_URL", "http://127.0.0.1:4000/api/preview/mcp"},
    {"DEVIDE_ARTIFACT_MCP_URL", "http://127.0.0.1:4000/api/artifacts/mcp"}
  ]

  test "self-test passes" do
    {out, 0} = System.cmd("python3", [@script, "--self-test"], stderr_to_stdout: true)
    assert out == ""
  end

  test "does not stamp ui.theme even when DEV_IDE_TERMINAL_SCHEME is set" do
    config = write_config("[ui]\ntheme = \"auto\"\n")

    assert {_, 0} =
             System.cmd("python3", [@script],
               env: base_env(config) ++ [{"DEV_IDE_TERMINAL_SCHEME", "light"}],
               stderr_to_stdout: true
             )

    content = File.read!(config)
    assert content =~ ~s/theme = "auto"/
    refute content =~ "grokday"
  end

  test "strips devide-* MCP blocks while preserving ui.theme and other sections" do
    config =
      write_config("""
      [ui]
      theme = "groknight"

      [mcp_servers.devide-alpha]
      url = "http://127.0.0.1:4000/api/terminals/mcp"

      [mcp_servers.keep-me]
      url = "http://example.test"
      """)

    assert {_, 0} =
             System.cmd("python3", [@script], env: base_env(config), stderr_to_stdout: true)

    content = File.read!(config)
    assert content =~ ~s/theme = "groknight"/
    assert content =~ "[mcp_servers.keep-me]"
    refute content =~ "devide-alpha"
  end

  test "write-claude-mcp includes the artifact server" do
    path = Path.join(System.tmp_dir!(), "artifact-mcp-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    assert {_, 0} =
             System.cmd(
               "python3",
               [
                 @script,
                 "write-claude-mcp",
                 path,
                 "http://127.0.0.1:4000/api/terminals/mcp",
                 "http://127.0.0.1:4000/api/preview/mcp",
                 "http://127.0.0.1:4000/api/artifacts/mcp"
               ],
               env: [{"DEVIDE_WORKSPACE_NAME", "Alpha Workspace"}],
               stderr_to_stdout: true
             )

    data = path |> File.read!() |> Jason.decode!()
    assert data["mcpServers"]["devide-artifact-alpha-workspace"]["url"] =~ "/api/artifacts/mcp"
  end

  defp write_config(body) do
    tmp = Path.join(System.tmp_dir!(), "merge-grok-#{System.unique_integer([:positive])}")
    config = Path.join([tmp, "home", ".grok", "config.toml"])
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, body)
    on_exit(fn -> File.rm_rf(tmp) end)
    config
  end

  # HOME drives the script's home-relative paths; System.cmd merges env with the
  # caller's, so Casein-managed shells' DEV_IDE_TERMINAL_SCHEME is cleared unless
  # a test sets it.
  defp base_env(config) do
    # config is <home>/.grok/config.toml, so HOME is two levels up.
    home = config |> Path.dirname() |> Path.dirname()
    @base_env ++ [{"HOME", home}, {"DEV_IDE_TERMINAL_SCHEME", nil}]
  end
end
