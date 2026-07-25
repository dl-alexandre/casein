defmodule CaseinWeb.API.AgentCapabilityControllerTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.Agents.{AgentCapabilityToken, AgentCapabilityTokens}
  alias Casein.Repo
  alias Casein.Workspaces

  @workspace_id "grok-cap-ws"
  @workspace_token "grok-cap-workspace-token"
  @global_token "grok-cap-global-token"
  @leader_id String.duplicate("b", 24)
  @bundle_digest String.duplicate("a", 64)
  @checkout_digest String.duplicate("c", 64)
  @pane_id "%7"

  setup do
    previous = %{
      api_token: Application.get_env(:casein, :api_token),
      workspace_tokens: Application.get_env(:casein, :workspace_api_tokens),
      tool_search: Application.get_env(:casein, :mcp_tool_search)
    }

    Application.put_env(:casein, :api_token, @global_token)
    Application.put_env(:casein, :workspace_api_tokens, %{@workspace_token => @workspace_id})
    Application.put_env(:casein, :mcp_tool_search, true)

    insert(:workspace_record,
      external_id: @workspace_id,
      name: @workspace_id,
      mode: "manual"
    )

    on_exit(fn ->
      restore(:api_token, previous.api_token)
      restore(:workspace_api_tokens, previous.workspace_tokens)
      restore(:mcp_tool_search, previous.tool_search)
    end)

    tmux_session = Casein.Terminals.tmux_workspace_session_prefix(@workspace_id) <> "agent"
    %{tmux_session: tmux_session}
  end

  test "workspace bearer mints a hash-at-rest, exact capability", %{
    conn: conn,
    tmux_session: tmux_session
  } do
    response = issue(conn, @workspace_token, tmux_session)

    assert response["token"] =~ "grokcap_"
    assert response["workspace_id"] == @workspace_id
    assert response["tmux_session_id"] == tmux_session
    assert response["leader_id"] == @leader_id
    assert response["pane_id"] == @pane_id
    assert response["workspace_mode"] == "manual"
    assert "terminal_list_sessions" in response["allowed_tools"]["terminal"]
    # Response shows *effective* tools (locked at issue); ceiling is separate.
    refute "terminal_send_command" in response["allowed_tools"]["terminal"]
    assert "terminal_send_command" in response["tool_ceiling"]["terminal"]

    record = Repo.get!(AgentCapabilityToken, response["capability_id"])
    assert record.token_hash == AgentCapabilityTokens.token_hash(response["token"])
    refute record.token_hash == response["token"]
    # Frozen ceiling includes write tools so a later unlock expands live grant.
    assert "terminal_send_command" in record.allowed_tools["terminal"]
    refute Map.has_key?(Application.get_env(:casein, :workspace_api_tokens), response["token"])
  end

  test "global and cross-workspace bearers cannot mint", %{conn: conn, tmux_session: session} do
    conn = post_json(conn, issue_path(), issue_params(session), @global_token)
    assert json_response(conn, 403)["error"] == "workspace_capability_issuer_required"

    Application.put_env(:casein, :workspace_api_tokens, %{"other-token" => "other-ws"})
    conn = post_json(build_conn(), issue_path(), issue_params(session), "other-token")
    assert json_response(conn, 403)["error"] == "workspace_forbidden"
  end

  test "capability filters tools, denies invoke_tool, and is session-bound", %{
    conn: conn,
    tmux_session: session
  } do
    token = issue(conn, @workspace_token, session)["token"]
    path = mcp_path(session)

    listed =
      build_conn()
      |> post_json(path, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, token)
      |> json_response(200)

    names = get_in(listed, ["result", "tools"]) |> Enum.map(& &1["name"])
    assert "terminal_list_sessions" in names
    assert "terminal_report_agent_state" in names
    refute "terminal_send_command" in names
    refute "search_tools" in names
    refute "invoke_tool" in names

    denied =
      build_conn()
      |> post_json(
        path,
        %{
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: %{
            name: "invoke_tool",
            arguments: %{name: "terminal_send_command", arguments: %{command: "id"}}
          }
        },
        token
      )
      |> json_response(200)

    assert get_in(denied, ["error", "data", "code"]) == "agent_capability_tool_forbidden"
    assert get_in(denied, ["error", "data", "reason"]) == "capability_meta_tool_forbidden"

    mismatch =
      build_conn()
      |> post_json(
        "/api/terminals/mcp?workspace_id=#{@workspace_id}&tmux_session=devide_other",
        %{jsonrpc: "2.0", id: 3, method: "tools/list"},
        token
      )

    assert json_response(mismatch, 403)["error"] == "capability_session_mismatch"
  end

  test "capability works only on MCP and its own lifecycle endpoint", %{
    conn: conn,
    tmux_session: session
  } do
    token = issue(conn, @workspace_token, session)["token"]

    current =
      build_conn()
      |> get_json("/api/agent-capabilities/current", token)
      |> json_response(200)

    assert current["workspace_id"] == @workspace_id
    assert current["leader_id"] == @leader_id

    # Reserved capability prefixes never take the static workspace-token path;
    # doing so would bypass DB expiry and revocation.
    Application.put_env(
      :casein,
      :workspace_api_tokens,
      Map.put(Application.get_env(:casein, :workspace_api_tokens), token, @workspace_id)
    )

    forbidden = get_json(build_conn(), "/api/workspaces/#{@workspace_id}/status", token)
    assert json_response(forbidden, 403)["error"] == "agent_capability_path_forbidden"

    revoked = delete_json(build_conn(), "/api/agent-capabilities/current", token)
    assert revoked.status == 204

    rejected = get_json(build_conn(), "/api/agent-capabilities/current", token)
    assert rejected.status == 401
  end

  test "the same bearer loses mutation tools immediately when write unlock is revoked", %{
    conn: conn,
    tmux_session: session
  } do
    until = DateTime.add(DateTime.utc_now(), 300, :second)
    assert {:ok, _} = Workspaces.grant_agent_write_unlock(@workspace_id, until, "operator")
    token = issue(conn, @workspace_token, session)["token"]
    path = mcp_path(session)

    before =
      build_conn()
      |> post_json(path, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, token)
      |> json_response(200)

    before_names = get_in(before, ["result", "tools"]) |> Enum.map(& &1["name"])
    assert "terminal_send_agent_command" in before_names
    # Write unlock grants raw send for same-session pane targeting.
    assert "terminal_send_command" in before_names
    assert "terminal_send_keys" in before_names

    assert {:ok, _} = Workspaces.revoke_agent_write_unlock(@workspace_id)

    after_revoke =
      build_conn()
      |> post_json(path, %{jsonrpc: "2.0", id: 2, method: "tools/list"}, token)
      |> json_response(200)

    after_names = get_in(after_revoke, ["result", "tools"]) |> Enum.map(& &1["name"])
    refute "terminal_send_agent_command" in after_names

    denied =
      build_conn()
      |> post_json(
        path,
        %{
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: %{name: "terminal_send_agent_command", arguments: %{command: "id"}}
        },
        token
      )
      |> json_response(200)

    assert get_in(denied, ["error", "data", "reason"]) == "capability_tool_forbidden"
  end

  test "streamable MCP session ids are bound to capability and surface", %{
    conn: conn,
    tmux_session: session
  } do
    token = issue(conn, @workspace_token, session)["token"]
    path = mcp_path(session)

    initialized =
      build_conn()
      |> post_json(
        path,
        %{jsonrpc: "2.0", id: 1, method: "initialize", params: %{}},
        token
      )

    assert initialized.status == 200
    assert [mcp_session_id] = get_resp_header(initialized, "mcp-session-id")

    other_session = Casein.Terminals.tmux_workspace_session_prefix(@workspace_id) <> "other"

    replacement =
      issue(build_conn(), @workspace_token, other_session, %{
        leader_id: String.duplicate("d", 24)
      })["token"]

    wrong_capability =
      build_conn()
      |> put_req_header("mcp-session-id", mcp_session_id)
      |> post_json(
        mcp_path(other_session),
        %{jsonrpc: "2.0", id: 2, method: "tools/list"},
        replacement
      )

    assert json_response(wrong_capability, 404)["error"] == "unknown_mcp_session"

    preview_path =
      "/api/preview/mcp?workspace_id=#{@workspace_id}&tmux_session=#{session}"

    wrong_surface =
      build_conn()
      |> put_req_header("mcp-session-id", mcp_session_id)
      |> post_json(preview_path, %{jsonrpc: "2.0", id: 3, method: "tools/list"}, token)

    assert json_response(wrong_surface, 404)["error"] == "unknown_mcp_session"

    accepted =
      build_conn()
      |> put_req_header("mcp-session-id", mcp_session_id)
      |> post_json(path, %{jsonrpc: "2.0", id: 4, method: "tools/list"}, token)

    assert json_response(accepted, 200)["result"]["tools"]
  end

  test "reissuing the same leader binding revokes the previous bearer", %{
    conn: conn,
    tmux_session: session
  } do
    first = issue(conn, @workspace_token, session)["token"]
    second = issue(build_conn(), @workspace_token, session)["token"]

    assert get_json(build_conn(), "/api/agent-capabilities/current", first).status == 401
    assert get_json(build_conn(), "/api/agent-capabilities/current", second).status == 200
  end

  defp issue(conn, token, session, overrides \\ %{}) do
    conn
    |> post_json(issue_path(), Map.merge(issue_params(session), overrides), token)
    |> json_response(201)
  end

  defp issue_path, do: "/api/workspaces/#{@workspace_id}/grok-agent-capabilities"

  defp issue_params(session) do
    %{
      tmux_session_id: session,
      pane_id: @pane_id,
      leader_id: @leader_id,
      bundle_digest: @bundle_digest,
      checkout_digest: @checkout_digest
    }
  end

  defp mcp_path(session) do
    "/api/terminals/mcp?workspace_id=#{@workspace_id}&tmux_session=#{session}"
  end

  defp post_json(conn, path, body, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> post(path, body)
  end

  defp get_json(conn, path, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(path)
  end

  defp delete_json(conn, path, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> delete(path)
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
