defmodule Casein.Agents.MCPUrlsTest do
  use ExUnit.Case, async: false

  alias Casein.Agents.MCPUrls

  @env_keys ~w(
    CASEIN_AGENT_MCP_BASE_URL
    CASEIN_API_BASE_URL
    CASEIN_URL
    PORT
  )

  setup do
    previous_app =
      Map.new(
        [:agent_mcp_base_url, :api_base_url, :canonical_public_origin],
        &{&1, Application.get_env(:casein, &1)}
      )

    previous_env = Map.new(@env_keys, &{&1, System.get_env(&1)})

    Enum.each(Map.keys(previous_app), &Application.delete_env(:casein, &1))
    Enum.each(@env_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous_app, fn {key, value} -> restore_app(key, value) end)
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
    end)

    :ok
  end

  test "known legacy Devbox environment regenerates canonical MCP endpoints" do
    Application.put_env(
      :casein,
      :canonical_public_origin,
      "https://casein.devbox.milcgroup.com"
    )

    System.put_env("CASEIN_URL", "https://devide.devbox.milcgroup.com")

    assert MCPUrls.terminal_url("ws-1") ==
             "https://casein.devbox.milcgroup.com/api/terminals/mcp?workspace_id=ws-1"

    assert MCPUrls.preview_url("ws-1") ==
             "https://casein.devbox.milcgroup.com/api/preview/mcp?workspace_id=ws-1"

    assert MCPUrls.artifact_url("ws-1") ==
             "https://casein.devbox.milcgroup.com/api/artifacts/mcp?workspace_id=ws-1"

    assert MCPUrls.code_url("ws-1") ==
             "https://casein.devbox.milcgroup.com/api/code/mcp?workspace_id=ws-1"
  end

  test "managed runtime pins generated service URLs above a stale workspace preview origin" do
    canonical = "https://casein.devbox.milcgroup.com"
    Application.put_env(:casein, :canonical_public_origin, canonical)
    Application.put_env(:casein, :agent_mcp_base_url, canonical)
    Application.put_env(:casein, :api_base_url, canonical)
    System.put_env("CASEIN_URL", "https://local.dalexandre-devide.devbox.milcgroup.com")

    assert MCPUrls.base_url() == canonical
    assert MCPUrls.api_base_url() == canonical

    runtime_source = File.read!("config/runtime.exs")
    assert runtime_source =~ "config :casein, :preview_app_url, canonical_devbox_url"
    assert runtime_source =~ "config :casein, :agent_mcp_base_url, canonical_devbox_url"
    assert runtime_source =~ "config :casein, :api_base_url, canonical_devbox_url"
  end

  test "explicit loopback and unrelated origins are never rewritten" do
    Application.put_env(
      :casein,
      :canonical_public_origin,
      "https://casein.devbox.milcgroup.com"
    )

    System.put_env("CASEIN_AGENT_MCP_BASE_URL", "http://127.0.0.1:4000")
    assert MCPUrls.base_url() == "http://127.0.0.1:4000"

    System.put_env("CASEIN_AGENT_MCP_BASE_URL", "https://preview.example.test")
    assert MCPUrls.base_url() == "https://preview.example.test"
  end

  test "client_mcp_json names servers and pins workspace_id" do
    System.put_env("CASEIN_AGENT_MCP_BASE_URL", "http://127.0.0.1:4000")

    json =
      MCPUrls.client_mcp_json(%{id: "ws-1", name: "Demo Workspace"}, "tok-1",
        base_url: "https://casein.example.test"
      )

    decoded = Jason.decode!(json)
    servers = decoded["mcpServers"]

    assert servers["casein-terminal-demo-workspace"]["url"] ==
             "https://casein.example.test/api/terminals/mcp?workspace_id=ws-1"

    assert servers["casein-preview-demo-workspace"]["headers"]["Authorization"] == "Bearer tok-1"
    assert servers["casein-artifact-demo-workspace"]["url"] =~ "workspace_id=ws-1"
  end

  test "ticket URLs keep the short-lived credential on its bound endpoint" do
    System.put_env("CASEIN_AGENT_MCP_BASE_URL", "http://127.0.0.1:4000")

    assert MCPUrls.ticket_url("terminal", "ws-1", "casein_ws-1_agent", "mcptkt_raw") ==
             "http://127.0.0.1:4000/api/terminals/mcp?ticket=mcptkt_raw&tmux_session=casein_ws-1_agent&workspace_id=ws-1"

    assert MCPUrls.ticket_url("artifact", "ws-1", nil, "mcptkt_raw") ==
             "http://127.0.0.1:4000/api/artifacts/mcp?ticket=mcptkt_raw&workspace_id=ws-1"

    assert MCPUrls.ticket_url("code", "ws-1", nil, "mcptkt_raw") ==
             "http://127.0.0.1:4000/api/code/mcp?ticket=mcptkt_raw&workspace_id=ws-1"
  end

  defp restore_app(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app(key, value), do: Application.put_env(:casein, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
