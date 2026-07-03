defmodule Scripts.MergeAgentMcpGrokThemeTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/lib/merge-agent-mcp.py", __DIR__)

  test "merge-agent-mcp grok theme helpers self-test" do
    {out, 0} = System.cmd("python3", [@script, "--self-test"], stderr_to_stdout: true)
    assert out == "" or String.contains?(out, "grok")
  end

  test "write_grok_config stamps ui.theme from DEV_IDE_TERMINAL_SCHEME" do
    tmp = Path.join(System.tmp_dir!(), "merge-grok-#{System.unique_integer([:positive])}")
    home = Path.join(tmp, "home")
    config = Path.join([home, ".grok", "config.toml"])
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, "[ui]\ntheme = \"auto\"\n")

    env = [
      {"HOME", home},
      {"DEVIDE_TERMINAL_MCP_URL", "http://127.0.0.1:4000/api/terminals/mcp"},
      {"DEVIDE_PREVIEW_MCP_URL", "http://127.0.0.1:4000/api/preview/mcp"},
      {"DEV_IDE_TERMINAL_SCHEME", "light"}
    ]

    assert {_, 0} = System.cmd("python3", [@script], env: env, stderr_to_stdout: true)
    assert File.read!(config) =~ ~s/theme = "grokday"/

    on_exit(fn -> File.rm_rf(tmp) end)
  end

  test "write_grok_config leaves theme untouched without DEV_IDE_TERMINAL_SCHEME" do
    tmp = Path.join(System.tmp_dir!(), "merge-grok-skip-#{System.unique_integer([:positive])}")
    home = Path.join(tmp, "home")
    config = Path.join([home, ".grok", "config.toml"])
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, "[ui]\ntheme = \"grokday\"\n")

    env = [
      {"HOME", home},
      {"DEVIDE_TERMINAL_MCP_URL", "http://127.0.0.1:4000/api/terminals/mcp"},
      {"DEVIDE_PREVIEW_MCP_URL", "http://127.0.0.1:4000/api/preview/mcp"},
      # System.cmd env: merges with the caller's environment; DevIDE-managed
      # shells export DEV_IDE_TERMINAL_SCHEME, so drop it explicitly.
      {"DEV_IDE_TERMINAL_SCHEME", nil}
    ]

    assert {_, 0} = System.cmd("python3", [@script], env: env, stderr_to_stdout: true)
    content = File.read!(config)
    assert content =~ ~s/theme = "grokday"/
    refute content =~ "groknight"

    on_exit(fn -> File.rm_rf(tmp) end)
  end
end
