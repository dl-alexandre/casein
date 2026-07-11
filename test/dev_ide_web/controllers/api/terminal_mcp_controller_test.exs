defmodule DevIdeWeb.API.TerminalMCPControllerTest do
  @moduledoc """
  HTTP transport + auth tests for POST /api/terminals/mcp.
  """
  use DevIdeWeb.ConnCase, async: false

  @token "test-terminal-mcp-token"

  setup do
    prev = Application.get_env(:dev_ide, :api_token)
    prev_workspace_tokens = Application.get_env(:dev_ide, :workspace_api_tokens)
    prev_allow_global = Application.get_env(:dev_ide, :allow_global_mcp_tool_calls)
    prev_tool_search = Application.get_env(:dev_ide, :mcp_tool_search)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:dev_ide, :api_token, @token)

    on_exit(fn ->
      restore(:api_token, prev)
      restore(:workspace_api_tokens, prev_workspace_tokens)
      restore(:allow_global_mcp_tool_calls, prev_allow_global)
      restore(:mcp_tool_search, prev_tool_search)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore_fake(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore_fake(:fake_tmux_windows, prev_fake_tmux_windows)
      restore_fake(:fake_tmux_panes, prev_fake_tmux_panes)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp restore_fake(key, nil), do: TmuxCtl.Test.FakeState.delete(key)
  defp restore_fake(key, val), do: TmuxCtl.Test.FakeState.put(key, val)

  defp post_mcp(conn, body, token),
    do: post_mcp(conn, body, token, "/api/terminals/mcp")

  defp post_mcp(conn, body, token, path) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> then(fn c ->
      if token, do: put_req_header(c, "authorization", "Bearer " <> token), else: c
    end)
    |> post(path, body)
  end

  test "requires a bearer token", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, nil)
    assert conn.status == 401
  end

  test "workspace_id query is advertised in initialize instructions", %{conn: conn} do
    conn =
      post_mcp(
        conn,
        %{jsonrpc: "2.0", id: 1, method: "initialize"},
        @token,
        "/api/terminals/mcp?workspace_id=ws-query"
      )

    assert %{"result" => %{"instructions" => instructions}} = json_response(conn, 200)
    assert instructions =~ "pre-scoped"
    assert instructions =~ "ws-query"
  end

  test "workspace-scoped token injects its workspace when query is omitted", %{conn: conn} do
    Application.put_env(:dev_ide, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

    conn =
      post_mcp(
        conn,
        %{jsonrpc: "2.0", id: 1, method: "initialize"},
        "ws-token"
      )

    assert %{"result" => %{"instructions" => instructions}} = json_response(conn, 200)
    assert instructions =~ "pre-scoped"
    assert instructions =~ "ws-scoped"
  end

  test "workspace-scoped token rejects another workspace query", %{conn: conn} do
    Application.put_env(:dev_ide, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

    conn =
      post_mcp(
        conn,
        %{jsonrpc: "2.0", id: 1, method: "initialize"},
        "ws-token",
        "/api/terminals/mcp?workspace_id=ws-other"
      )

    assert json_response(conn, 403) == %{"error" => "workspace_forbidden"}
  end

  test "global token cannot call Terminal MCP tools", %{conn: conn} do
    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "terminal_list_sessions",
            arguments: %{workspace_id: "ws-other"}
          }
        },
        @token,
        "/api/terminals/mcp?workspace_id=ws-query"
      )

    assert %{
             "error" => "workspace_scoped_token_required",
             "code" => "workspace_scoped_token_required",
             "error_version" => "mcp-auth-v1",
             "tool" => "terminal_list_sessions"
           } = json_response(conn, 403)
  end

  test "global token CAN call tools box-wide when allow_global_mcp_tool_calls is enabled",
       %{conn: conn} do
    Application.put_env(:dev_ide, :allow_global_mcp_tool_calls, true)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "devide_ws_agent" => [
        %{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 0}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      "devide_ws_agent" => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "bash",
          current_path: "/workspace"
        }
      ]
    })

    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "terminal_send_command",
            arguments: %{
              session: "devide_ws_agent",
              command: "echo orchestrator"
            }
          }
        },
        @token
      )

    assert %{"result" => %{"structuredContent" => %{"status" => "sent"}}} =
             json_response(conn, 200)

    refute conn.resp_body =~ "workspace_scoped_token_required"
  end

  test "global token cannot call Terminal MCP command tools", %{conn: conn} do
    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "terminal_send_command",
            arguments: %{
              session: "devide_ws_query_agent",
              command: "echo should-not-run"
            }
          }
        },
        @token,
        "/api/terminals/mcp?workspace_id=ws-query"
      )

    assert %{
             "error" => "workspace_scoped_token_required",
             "code" => "workspace_scoped_token_required",
             "error_version" => "mcp-auth-v1",
             "tool" => "terminal_send_command"
           } = json_response(conn, 403)

    refute conn.resp_body =~ "should-not-run"
  end

  test "workspace-scoped token can call Terminal MCP mutation tools", %{conn: conn} do
    Application.put_env(:dev_ide, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "devide_ws-scoped_agent" => [
        %{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 0}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      "devide_ws-scoped_agent" => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "bash",
          current_path: "/workspace"
        }
      ]
    })

    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "terminal_send_command",
            arguments: %{
              session: "devide_ws-scoped_agent",
              command: "echo scoped"
            }
          }
        },
        "ws-token"
      )

    assert %{
             "result" => %{
               "structuredContent" => %{"status" => "sent"}
             }
           } = json_response(conn, 200)

    assert_receive {:fake_tmux_send_command, "devide_ws-scoped_agent", "devide_ws-scoped_agent",
                    "echo scoped", []}
  end

  describe "tool search (DEV_IDE_MCP_TOOL_SEARCH)" do
    test "tools/list returns the full surface when disabled (default)", %{conn: conn} do
      conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, @token)
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)
      names = Enum.map(tools, & &1["name"])

      assert "terminal_set_agent_label" in names
      refute "search_tools" in names
      assert length(tools) > 8
    end

    test "tools/list returns only core + meta tools when enabled", %{conn: conn} do
      Application.put_env(:dev_ide, :mcp_tool_search, true)

      conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, @token)
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)
      names = Enum.map(tools, & &1["name"])

      # core stays native
      assert "terminal_list_sessions" in names
      assert "terminal_send_agent_command" in names
      assert "terminal_wait_agent_state" in names
      # meta-tools advertised
      assert "search_tools" in names
      assert "invoke_tool" in names
      # long tail hidden from the advertised list
      refute "terminal_set_agent_label" in names
      refute "terminal_report_worktree" in names
      assert length(tools) == 8
    end

    test "search_tools finds a long-tail tool by natural-language intent", %{conn: conn} do
      Application.put_env(:dev_ide, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

      conn =
        post_mcp(
          conn,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{
              name: "search_tools",
              arguments: %{query: "set a label on an agent pane"}
            }
          },
          "ws-token"
        )

      %{"result" => %{"structuredContent" => %{"matches" => matches}}} =
        json_response(conn, 200)

      assert "terminal_set_agent_label" in Enum.map(matches, & &1["name"])
    end

    test "invoke_tool runs a discovered tool through normal scope + audit", %{conn: conn} do
      Application.put_env(:dev_ide, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})
      Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        "devide_ws-scoped_agent" => [
          %{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 0}
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        "devide_ws-scoped_agent" => [
          %{
            id: "%1",
            window_id: "@1",
            index: 0,
            active: true,
            current_command: "bash",
            current_path: "/workspace"
          }
        ]
      })

      conn =
        post_mcp(
          conn,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{
              name: "invoke_tool",
              arguments: %{
                name: "terminal_send_command",
                arguments: %{session: "devide_ws-scoped_agent", command: "echo via-invoke"}
              }
            }
          },
          "ws-token"
        )

      assert %{"result" => %{"structuredContent" => %{"status" => "sent"}}} =
               json_response(conn, 200)

      assert_receive {:fake_tmux_send_command, "devide_ws-scoped_agent", "devide_ws-scoped_agent",
                      "echo via-invoke", []}
    end

    test "invoke_tool refuses to call a meta-tool", %{conn: conn} do
      Application.put_env(:dev_ide, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

      conn =
        post_mcp(
          conn,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{
              name: "invoke_tool",
              arguments: %{name: "search_tools", arguments: %{query: "x"}}
            }
          },
          "ws-token"
        )

      assert %{"result" => %{"isError" => true}} = json_response(conn, 200)
    end
  end

  test "notifications get a 202 with no JSON-RPC body", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", method: "notifications/initialized"}, @token)
    assert conn.status == 202
    assert conn.resp_body == ""
  end
end
