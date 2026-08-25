defmodule CaseinWeb.Plugs.ApiAuthTest do
  use Casein.TestCase, async: false

  import Plug.Test
  import Plug.Conn

  alias CaseinWeb.Plugs.ApiAuth

  @workspace_id "ws-scoped"
  @workspace_token "ws-token-secret"
  @other_workspace "ws-other"

  @mcp_paths [
    "/api/terminals/mcp",
    "/api/preview/mcp",
    "/api/artifacts/mcp",
    "/api/code/mcp"
  ]

  setup do
    prev_api_token = Application.get_env(:casein, :api_token)
    prev_workspace_tokens = Application.get_env(:casein, :workspace_api_tokens)
    prev_env_token = System.get_env("CASEIN_API_TOKEN")
    prev_env_workspace_tokens = System.get_env("CASEIN_WORKSPACE_API_TOKENS")

    System.delete_env("CASEIN_API_TOKEN")
    System.delete_env("CASEIN_WORKSPACE_API_TOKENS")
    Application.delete_env(:casein, :api_token)

    Application.put_env(:casein, :workspace_api_tokens, %{
      @workspace_token => @workspace_id
    })

    on_exit(fn ->
      restore_env(:api_token, prev_api_token)
      restore_env(:workspace_api_tokens, prev_workspace_tokens)

      case prev_env_token do
        nil -> System.delete_env("CASEIN_API_TOKEN")
        val -> System.put_env("CASEIN_API_TOKEN", val)
      end

      case prev_env_workspace_tokens do
        nil -> System.delete_env("CASEIN_WORKSPACE_API_TOKENS")
        val -> System.put_env("CASEIN_WORKSPACE_API_TOKENS", val)
      end
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_env(key, val), do: Application.put_env(:casein, key, val)

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

  test "rotated workspace bearer returns explicit stale_grant on MCP" do
    Application.put_env(:casein, :workspace_api_tokens_retired, %{
      "retired-ws-token" => @workspace_id
    })

    conn =
      conn(:post, "/api/terminals/mcp?workspace_id=#{@workspace_id}")
      |> put_req_header("authorization", "Bearer retired-ws-token")
      |> ApiAuth.call([])

    assert conn.halted
    assert conn.status == 401
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "stale_grant"
    assert body["code"] == "stale_grant"
    assert body["kind"] == "workspace_token"
    assert body["reason"] == "rotated"
    assert body["message"] =~ "stale"
  end

  test "revoked grok capability bearer returns explicit stale_grant on MCP" do
    # Capability tokens are DB-backed; check out the sandbox for this case only.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Casein.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Casein.Repo, {:shared, self()})

    {:ok, raw, record} =
      Casein.Agents.AgentCapabilityTokens.create_for_grok(%{
        workspace_id: @workspace_id,
        tmux_session_id: "casein_ws-scoped_agent",
        pane_id: "%1",
        leader_id: String.duplicate("a", 24),
        bundle_digest: String.duplicate("b", 64),
        workspace_mode: "manual",
        allowed_tools: %{"terminal" => ["terminal_list_sessions"]}
      })

    assert {:ok, _} = Casein.Agents.AgentCapabilityTokens.revoke_current(record.id)

    conn =
      conn(
        :post,
        "/api/terminals/mcp?workspace_id=#{@workspace_id}&tmux_session=casein_ws-scoped_agent"
      )
      |> put_req_header("authorization", "Bearer " <> raw)
      |> ApiAuth.call([])

    assert conn.halted
    assert conn.status == 401
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "stale_grant"
    assert body["kind"] == "agent_capability"
    assert body["reason"] == "revoked"
  end
end
