defmodule CaseinWeb.Plugs.ApiAuthMultiWorkspaceTest do
  @moduledoc """
  OneBackend-v3#20161: one bearer registered for a *list* of workspaces must
  be able to address any of them over MCP — and none outside the list.
  """
  use Casein.TestCase, async: false

  import Plug.Test
  import Plug.Conn

  alias CaseinWeb.Plugs.ApiAuth

  @token "multi-ws-token-secret"
  @entitled ["ws-factory-a", "ws-factory-b", "ws-design-c"]
  @outside "ws-fixes"

  setup do
    prev_api_token = Application.get_env(:casein, :api_token)
    prev_workspace_tokens = Application.get_env(:casein, :workspace_api_tokens)
    prev_env_token = System.get_env("CASEIN_API_TOKEN")
    prev_env_workspace_tokens = System.get_env("CASEIN_WORKSPACE_API_TOKENS")

    System.delete_env("CASEIN_API_TOKEN")
    System.delete_env("CASEIN_WORKSPACE_API_TOKENS")
    Application.delete_env(:casein, :api_token)
    Application.put_env(:casein, :workspace_api_tokens, %{@token => @entitled})

    on_exit(fn ->
      restore_env(:api_token, prev_api_token)
      restore_env(:workspace_api_tokens, prev_workspace_tokens)
      restore_sys("CASEIN_API_TOKEN", prev_env_token)
      restore_sys("CASEIN_WORKSPACE_API_TOKENS", prev_env_workspace_tokens)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_env(key, val), do: Application.put_env(:casein, key, val)
  defp restore_sys(key, nil), do: System.delete_env(key)
  defp restore_sys(key, val), do: System.put_env(key, val)

  defp call_mcp(query \\ nil) do
    url = if query, do: "/api/terminals/mcp?" <> query, else: "/api/terminals/mcp"

    conn(:post, url)
    |> put_req_header("authorization", "Bearer " <> @token)
    |> ApiAuth.call([])
  end

  test "every entitled workspace is addressable by pinning it in the URL" do
    for workspace_id <- @entitled do
      conn = call_mcp("workspace_id=#{workspace_id}")

      refute conn.halted, workspace_id
      assert conn.assigns.api_token_scope == {:workspace, workspace_id}
      assert conn.assigns.api_workspace_id == workspace_id
    end
  end

  test "a workspace outside the list is still refused" do
    conn = call_mcp("workspace_id=#{@outside}")

    assert conn.halted
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "workspace_forbidden"}
    refute Map.has_key?(conn.assigns, :api_workspace_id)
  end

  test "an unpinned URL falls back to the first entitled workspace" do
    conn = call_mcp()

    refute conn.halted
    assert conn.assigns.api_workspace_id == "ws-factory-a"
  end

  test "the full entitlement is on the conn for surfaces that want to show it" do
    conn = call_mcp("workspace_id=ws-factory-b")

    assert conn.assigns.api_workspace_ids == @entitled
  end
end
