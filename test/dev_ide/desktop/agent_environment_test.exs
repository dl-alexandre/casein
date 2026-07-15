defmodule DevIDE.Desktop.AgentEnvironmentTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Desktop.AgentEnvironment

  setup do
    previous_tokens = Application.get_env(:dev_ide, :workspace_api_tokens)
    previous_store = Application.get_env(:dev_ide, :workspace_tokens_store)
    previous_base = Application.get_env(:dev_ide, :agent_mcp_base_url)
    root = Path.join(System.tmp_dir!(), "desktop-agent-env-#{System.unique_integer([:positive])}")
    checkout = Path.join(root, "checkout")
    store = Path.join(root, "tokens.json")
    File.mkdir_p!(checkout)

    Application.put_env(:dev_ide, :workspace_api_tokens, %{})
    Application.put_env(:dev_ide, :workspace_tokens_store, store)
    Application.put_env(:dev_ide, :agent_mcp_base_url, "http://127.0.0.1:58068")

    on_exit(fn ->
      restore(:workspace_api_tokens, previous_tokens)
      restore(:workspace_tokens_store, previous_store)
      restore(:agent_mcp_base_url, previous_base)
      File.rm_rf(root)
    end)

    %{checkout: checkout}
  end

  test "build injects scoped endpoints and project discovery for native agents", %{
    checkout: checkout
  } do
    workspace = %{id: "desktop-ws", name: "Desktop Workspace", path: checkout}

    assert {:ok, env} = AgentEnvironment.build(workspace, checkout)
    assert env["DEV_IDE_API_TOKEN"] =~ ~r/^[0-9a-f]{64}$/
    assert env["DEVIDE_WORKSPACE_ID"] == "desktop-ws"
    assert env["DEVIDE_CHECKOUT"] == checkout

    assert env["DEVIDE_TERMINAL_MCP_URL"] ==
             "http://127.0.0.1:58068/api/terminals/mcp?workspace_id=desktop-ws"

    config = File.read!(Path.join(checkout, ".mcp.json"))
    assert config =~ "devide-terminal-desktop-workspace"
    assert config =~ "Bearer ${DEV_IDE_API_TOKEN}"
    refute config =~ env["DEV_IDE_API_TOKEN"]
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
