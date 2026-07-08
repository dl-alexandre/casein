defmodule DevIdeWeb.Plugs.ApiAuthTest do
  use DevIDE.TestCase, async: false

  import Plug.Test
  import Plug.Conn

  alias DevIdeWeb.Plugs.ApiAuth

  @workspace_id "ws-scoped"
  @workspace_token "ws-token-secret"
  @other_workspace "ws-other"

  @mcp_paths [
    "/api/terminals/mcp",
    "/api/preview/mcp",
    "/api/artifacts/mcp"
  ]

  setup do
    prev_api_token = Application.get_env(:dev_ide, :api_token)
    prev_workspace_tokens = Application.get_env(:dev_ide, :workspace_api_tokens)
    prev_env_token = System.get_env("DEV_IDE_API_TOKEN")
    prev_env_workspace_tokens = System.get_env("DEV_IDE_WORKSPACE_API_TOKENS")

    System.delete_env("DEV_IDE_API_TOKEN")
    System.delete_env("DEV_IDE_WORKSPACE_API_TOKENS")
    Application.delete_env(:dev_ide, :api_token)

    Application.put_env(:dev_ide, :workspace_api_tokens, %{
      @workspace_token => @workspace_id
    })

    on_exit(fn ->
      restore_env(:api_token, prev_api_token)
      restore_env(:workspace_api_tokens, prev_workspace_tokens)

      case prev_env_token do
        nil -> System.delete_env("DEV_IDE_API_TOKEN")
        val -> System.put_env("DEV_IDE_API_TOKEN", val)
      end

      case prev_env_workspace_tokens do
        nil -> System.delete_env("DEV_IDE_WORKSPACE_API_TOKENS")
        val -> System.put_env("DEV_IDE_WORKSPACE_API_TOKENS", val)
      end
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, val), do: Application.put_env(:dev_ide, key, val)

  defp call_mcp(path, query \\ nil) do
    url = if query, do: path <> "?" <> query, else: path

    conn(:post, url)
    |> put_req_header("authorization", "Bearer " <> @workspace_token)
    |> ApiAuth.call([])
  end

  describe "MCP workspace gate (plug layer)" do
    for path <- @mcp_paths do
      test "#{path} authorizes scoped token when workspace_id query is omitted" do
        conn = call_mcp(unquote(path))

        refute conn.halted
        assert conn.assigns.api_token_scope == {:workspace, @workspace_id}
        assert conn.assigns.api_workspace_id == @workspace_id
      end

      test "#{path} authorizes scoped token when workspace_id query is empty" do
        conn = call_mcp(unquote(path), "workspace_id=")

        refute conn.halted
        assert conn.assigns.api_workspace_id == @workspace_id
      end

      test "#{path} authorizes scoped token when workspace_id matches token workspace" do
        conn = call_mcp(unquote(path), "workspace_id=#{@workspace_id}")

        refute conn.halted
        assert conn.assigns.api_workspace_id == @workspace_id
      end

      test "#{path} rejects scoped token when workspace_id names another workspace" do
        conn = call_mcp(unquote(path), "workspace_id=#{@other_workspace}")

        assert conn.halted
        assert conn.status == 403
        assert Jason.decode!(conn.resp_body) == %{"error" => "workspace_forbidden"}
        refute Map.has_key?(conn.assigns, :api_workspace_id)
      end
    end
  end

  test "workspace path routes still require matching workspace_id in path" do
    conn =
      conn(:get, "/api/workspaces/#{@other_workspace}/sessions")
      |> put_req_header("authorization", "Bearer " <> @workspace_token)
      |> ApiAuth.call([])

    assert conn.halted
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "workspace_forbidden"}
  end
end
