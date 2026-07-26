defmodule Casein.Desktop.AgentEnvironmentTest do
  use Casein.TestCase, async: false

  alias Casein.Desktop.AgentEnvironment

  setup do
    previous_tokens = Application.get_env(:casein, :workspace_api_tokens)
    previous_store = Application.get_env(:casein, :workspace_tokens_store)
    previous_base = Application.get_env(:casein, :agent_mcp_base_url)
    previous_home = System.get_env("HOME")
    root = Path.join(System.tmp_dir!(), "desktop-agent-env-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    checkout = Path.join(root, "checkout")
    store = Path.join(root, "tokens.json")
    File.mkdir_p!(home)
    File.mkdir_p!(checkout)

    System.put_env("HOME", home)
    Application.put_env(:casein, :workspace_api_tokens, %{})
    Application.put_env(:casein, :workspace_tokens_store, store)
    Application.put_env(:casein, :agent_mcp_base_url, "http://127.0.0.1:58068")

    on_exit(fn ->
      restore(:workspace_api_tokens, previous_tokens)
      restore(:workspace_tokens_store, previous_store)
      restore(:agent_mcp_base_url, previous_base)
      restore_system_env("HOME", previous_home)
      remove_tree(root)
    end)

    %{checkout: checkout}
  end

  test "build injects scoped endpoints and stages native-agent capabilities outside the project",
       %{
         checkout: checkout
       } do
    workspace = %{id: "desktop-ws", name: "Desktop Workspace", path: checkout}

    assert {:ok, env} = AgentEnvironment.build(workspace, checkout)
    assert env["CASEIN_API_TOKEN"] =~ ~r/^[0-9a-f]{64}$/
    assert env["CASEIN_WORKSPACE_ID"] == "desktop-ws"
    assert env["CASEIN_CHECKOUT"] == checkout

    assert env["CASEIN_TERMINAL_MCP_URL"] ==
             "http://127.0.0.1:58068/api/terminals/mcp?workspace_id=desktop-ws"

    refute File.exists?(Path.join(checkout, ".mcp.json"))

    staging = env["CASEIN_AGENT_MCP_HOME"]
    config = File.read!(Path.join(staging, ".mcp.json"))
    assert config =~ "casein-terminal-desktop-workspace"
    assert config =~ "Bearer ${CASEIN_API_TOKEN}"
    refute config =~ env["CASEIN_API_TOKEN"]

    staged_env = File.read!(Path.join(staging, "env.sh"))
    assert staged_env =~ "CASEIN_GROK_BUNDLE_DIR="
    assert staged_env =~ "CASEIN_GROK_BUNDLE_DIGEST="
    assert staged_env =~ "CASEIN_GROK_LEADER_SOCKET="
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp remove_tree(root) do
    root
    |> writable_descendants()
    |> Enum.each(fn path -> File.chmod(path, if(File.dir?(path), do: 0o700, else: 0o600)) end)

    File.rm_rf(root)
  end

  defp writable_descendants(path) do
    children =
      case File.ls(path) do
        {:ok, names} -> Enum.flat_map(names, &writable_descendants(Path.join(path, &1)))
        _ -> []
      end

    children ++ [path]
  end
end
