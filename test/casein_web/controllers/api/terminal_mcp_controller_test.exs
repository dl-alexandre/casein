defmodule CaseinWeb.API.TerminalMCPControllerTest do
  @moduledoc """
  HTTP transport + auth tests for POST /api/terminals/mcp.
  """
  use CaseinWeb.ConnCase, async: false

  @token "test-terminal-mcp-token"

  setup do
    prev = Application.get_env(:casein, :api_token)
    prev_workspace_tokens = Application.get_env(:casein, :workspace_api_tokens)
    prev_allow_global = Application.get_env(:casein, :allow_global_mcp_tool_calls)
    prev_tool_search = Application.get_env(:casein, :mcp_tool_search)
    prev_workspace_digest = Application.get_env(:casein, :workspace_digest)
    prev_situation_server = Application.get_env(:casein, :situation_server)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:casein, :api_token, @token)

    on_exit(fn ->
      restore(:api_token, prev)
      restore(:workspace_api_tokens, prev_workspace_tokens)
      restore(:allow_global_mcp_tool_calls, prev_allow_global)
      restore(:mcp_tool_search, prev_tool_search)
      restore(:workspace_digest, prev_workspace_digest)
      restore(:situation_server, prev_situation_server)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore_fake(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore_fake(:fake_tmux_windows, prev_fake_tmux_windows)
      restore_fake(:fake_tmux_panes, prev_fake_tmux_panes)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

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
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

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
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

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
    Application.put_env(:casein, :allow_global_mcp_tool_calls, true)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "casein_ws_agent" => [
        %{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 0}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      "casein_ws_agent" => [
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
              session: "casein_ws_agent",
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

  test "self-serve orchestrator token CAN call tools with allow_global_mcp_tool_calls off",
       %{conn: conn} do
    # Default posture: global tool-calls are OFF. A minted orchestrator token is
    # non-global, so it is NOT rejected — no CASEIN_ALLOW_GLOBAL_MCP_TOOL_CALLS
    # needed. This is the safe, revocable path.
    refute Application.get_env(:casein, :allow_global_mcp_tool_calls, false)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

    {:ok, raw, _record} =
      Casein.Agents.OrchestratorTokens.create_for_subject(%{
        id: "alice",
        username: "alice",
        email: "alice@example.com",
        role: :user
      })

    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "terminal_list_sessions", arguments: %{}}
        },
        raw
      )

    assert conn.status == 200
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
              session: "casein_ws_query_agent",
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
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "casein_ws-scoped_agent" => [
        %{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 0}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      "casein_ws-scoped_agent" => [
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
              session: "casein_ws-scoped_agent",
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

    # No pane supplied: the implicit target early-binds to the session's
    # active pane id at call time instead of riding the session name.
    assert_receive {:fake_tmux_send_command, "%1", "%1", "echo scoped", []}
  end

  test "X-Casein-Caller-Pane header anchors caller-pane terminal tools", %{conn: conn} do
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "casein_ws-scoped_agent" => [
        %{id: "@1", index: 0, name: "agent", active: true, panes: 2, activity: 0}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      "casein_ws-scoped_agent" => [
        %{id: "%1", window_id: "@1", index: 0, active: true, current_command: "claude"},
        %{id: "%2", window_id: "@1", index: 1, active: false, current_command: "bash"}
      ]
    })

    conn =
      conn
      |> put_req_header("x-casein-caller-pane", "%1")
      |> post_mcp(
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "terminal_topology",
            arguments: %{session: "casein_ws-scoped_agent"}
          }
        },
        "ws-token"
      )

    assert %{
             "result" => %{
               "structuredContent" => %{
                 "caller" => %{
                   "pane" => "%1",
                   "adjacent_panes" => [%{"id" => "%2"}]
                 }
               }
             }
           } = json_response(conn, 200)
  end

  test "tmux_session query makes exact session discovery win over attached ambiguity", %{
    conn: conn
  } do
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

    target = "casein_ws-scoped_wt-dev-ide"
    other_a = "casein_ws-scoped_wt-a"
    other_b = "casein_ws-scoped_wt-b"

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      target => [%{id: "@1", index: 0, name: "operator", active: true, panes: 1, activity: 1}],
      other_a => [%{id: "@2", index: 0, name: "other-a", active: true, panes: 1, activity: 2}],
      other_b => [%{id: "@3", index: 0, name: "other-b", active: true, panes: 1, activity: 3}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      target => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "bash",
          current_path: "/data/workspaces/dalexandre/dev_ide",
          role: "operator"
        }
      ],
      other_a => [%{id: "%2", window_id: "@2", index: 0, active: true}],
      other_b => [%{id: "%3", window_id: "@3", index: 0, active: true}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_session_meta, %{
      target => %{attached: true, session_alias: "dev_ide"},
      other_a => %{attached: true},
      other_b => %{attached: true}
    })

    on_exit(fn -> TmuxCtl.Test.FakeState.delete(:fake_tmux_session_meta) end)

    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "terminal_list_sessions", arguments: %{}}
        },
        "ws-token",
        "/api/terminals/mcp?workspace_id=ws-scoped&tmux_session=#{target}"
      )

    assert %{
             "result" => %{
               "structuredContent" => %{
                 "sessions" => [
                   %{
                     "session" => ^target,
                     "session_alias" => "dev_ide",
                     "operator_pane_id" => "%1",
                     "paths" => ["/data/workspaces/dalexandre/dev_ide"]
                   }
                 ],
                 "recommended_session" => ^target
               }
             }
           } = json_response(conn, 200)

    refute conn.resp_body =~ "ambiguous"
  end

  test "malformed caller-pane headers are ignored", %{conn: conn} do
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "casein_ws-scoped_agent" => [
        %{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 0}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      "casein_ws-scoped_agent" => [
        %{id: "%1", window_id: "@1", index: 0, active: true, current_command: "bash"}
      ]
    })

    conn =
      conn
      # An unexpanded client-side env placeholder must not become a pane id.
      |> put_req_header("x-casein-caller-pane", "${CASEIN_CALLER_PANE}")
      |> post_mcp(
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "terminal_topology",
            arguments: %{session: "casein_ws-scoped_agent"}
          }
        },
        "ws-token"
      )

    assert %{"result" => %{"structuredContent" => payload}} = json_response(conn, 200)
    refute Map.has_key?(payload, "caller")
  end

  test "a workspace-token mutation is audited with the ws:<id> actor", %{conn: conn} do
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "casein_ws-scoped_agent" => [
        %{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 0}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      "casein_ws-scoped_agent" => [
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

    Casein.Audit.MemoryAdapter.clear()
    on_exit(fn -> Casein.Audit.MemoryAdapter.clear() end)

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
              session: "casein_ws-scoped_agent",
              command: "echo actor"
            }
          }
        },
        "ws-token"
      )

    assert %{"result" => %{"structuredContent" => %{"status" => "sent"}}} =
             json_response(conn, 200)

    [event] = Casein.Audit.recent_for("ws-scoped", 1)
    assert event.action == "agent.terminal_terminal_send_command"
    assert event.actor_id == "ws:ws-scoped"
    assert event.source == "terminal_mcp"
    assert event.tool == "terminal_send_command"
  end

  describe "tool search (CASEIN_MCP_TOOL_SEARCH)" do
    test "tools/list returns the full surface when disabled (default)", %{conn: conn} do
      conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, @token)
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)
      names = Enum.map(tools, & &1["name"])

      assert "terminal_set_agent_label" in names
      refute "search_tools" in names
      assert length(tools) > 8
    end

    test "tools/list returns only core + meta tools when enabled", %{conn: conn} do
      Application.put_env(:casein, :mcp_tool_search, true)

      conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, @token)
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)
      names = Enum.map(tools, & &1["name"])

      # core stays native
      assert "terminal_list_sessions" in names
      assert "terminal_send_agent_command" in names
      assert "terminal_wait_agent_state" in names
      # Steering a busy fleet is a hot loop: an orchestrator must be able to
      # leave a message without a discovery round-trip first.
      assert "terminal_set_next_prompt" in names
      # meta-tools advertised
      assert "search_tools" in names
      assert "invoke_tool" in names
      # long tail hidden from the advertised list
      refute "terminal_set_agent_label" in names
      refute "terminal_report_worktree" in names
      refute "terminal_get_next_prompt" in names
      assert length(tools) == 9
    end

    test "search_tools finds a long-tail tool by natural-language intent", %{conn: conn} do
      Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

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

    test "search_tools from the terminal endpoint finds tools on OTHER servers", %{conn: conn} do
      Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

      conn =
        post_mcp(
          conn,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: "search_tools", arguments: %{query: "take a screenshot of the page"}}
          },
          "ws-token"
        )

      %{"result" => %{"structuredContent" => %{"matches" => matches}}} =
        json_response(conn, 200)

      shot = Enum.find(matches, &(&1["name"] == "preview_screenshot"))
      assert shot, "expected a cross-server preview match from the terminal endpoint"
      assert shot["server"] == "preview"
    end

    test "invoke_tool with an unknown tool name returns a tool error", %{conn: conn} do
      Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

      conn =
        post_mcp(
          conn,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: "invoke_tool", arguments: %{name: "no_such_tool", arguments: %{}}}
          },
          "ws-token"
        )

      assert %{"result" => %{"isError" => true}} = json_response(conn, 200)
    end

    test "invoke_tool runs a discovered tool through normal scope + audit", %{conn: conn} do
      Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})
      Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        "casein_ws-scoped_agent" => [
          %{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 0}
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        "casein_ws-scoped_agent" => [
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
                arguments: %{session: "casein_ws-scoped_agent", command: "echo via-invoke"}
              }
            }
          },
          "ws-token"
        )

      assert %{"result" => %{"structuredContent" => %{"status" => "sent"}}} =
               json_response(conn, 200)

      # Implicit targets early-bind to the active pane id at call time.
      assert_receive {:fake_tmux_send_command, "%1", "%1", "echo via-invoke", []}
    end

    test "invoke_tool refuses to call a meta-tool", %{conn: conn} do
      Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

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

  describe "workspace digest (CASEIN_WORKSPACE_DIGEST)" do
    test "tools/list hides workspace_digest when disabled (default)", %{conn: conn} do
      conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, @token)
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      refute "workspace_digest" in Enum.map(tools, & &1["name"])
    end

    test "tools/list advertises workspace_digest when enabled", %{conn: conn} do
      Application.put_env(:casein, :workspace_digest, true)

      conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, @token)
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)
      digest = Enum.find(tools, &(&1["name"] == "workspace_digest"))

      assert digest, "expected workspace_digest to be advertised when the flag is on"
      assert digest["metadata"]["mutation"] == false
    end

    test "workspace_digest returns the digest through scope dispatch", %{conn: conn} do
      Application.put_env(:casein, :workspace_digest, true)
      Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})
      Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

      conn =
        post_mcp(
          conn,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: "workspace_digest", arguments: %{}}
          },
          "ws-token"
        )

      assert %{"result" => %{"structuredContent" => digest}} = json_response(conn, 200)

      # The pre-scoped token injects its workspace id; sections are present
      # even when the workspace has no live sessions or worktrees.
      assert digest["workspace_id"] == "ws-scoped"
      assert is_binary(digest["generated_at"])
      assert is_map(digest["freshness"])
      assert is_list(digest["sessions"])
      assert is_list(digest["worktrees"])
      assert is_map(digest["deploy"])
      assert is_map(digest["activity"])
      assert is_list(digest["risks"])
    end

    test "workspace_digest is served by the live SituationServer when its flag is on",
         %{conn: conn} do
      Application.put_env(:casein, :workspace_digest, true)
      Application.put_env(:casein, :situation_server, true)
      Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-live"})
      Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

      # Keep the server's async worktree sweep away from the box's real
      # agent-worktree root.
      prev_roots = Application.get_env(:casein, :agent_worktree_roots)

      Application.put_env(:casein, :agent_worktree_roots, [
        Path.join(System.tmp_dir!(), "casein-situation-test-empty")
      ])

      on_exit(fn ->
        case Casein.Operator.SituationServer.whereis("ws-live") do
          nil -> :ok
          pid -> GenServer.stop(pid)
        end

        restore(:agent_worktree_roots, prev_roots)
      end)

      conn =
        post_mcp(
          conn,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: "workspace_digest", arguments: %{}}
          },
          "ws-token"
        )

      assert %{"result" => %{"structuredContent" => digest}} = json_response(conn, 200)
      assert digest["workspace_id"] == "ws-live"
      assert is_list(digest["risks"])

      # The request spun up (and was answered by) the live per-workspace server.
      assert is_pid(Casein.Operator.SituationServer.whereis("ws-live")),
             "expected the digest request to start the live SituationServer"
    end
  end

  test "notifications get a 202 with no JSON-RPC body", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", method: "notifications/initialized"}, @token)
    assert conn.status == 202
    assert conn.resp_body == ""
  end
end
