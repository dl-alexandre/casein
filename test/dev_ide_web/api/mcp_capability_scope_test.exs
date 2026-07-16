defmodule DevIdeWeb.API.MCPCapabilityScopeTest do
  use ExUnit.Case, async: true

  alias DevIdeWeb.API.MCPCapabilityScope

  @claims %{
    workspace_id: "ws",
    tmux_session_id: "devide_ws_agent",
    pane_id: "%7",
    bundle_digest: String.duplicate("a", 64),
    leader_id: String.duplicate("b", 24)
  }

  defp opts do
    [
      agent_capability: @claims,
      agent_capability_surface: "terminal",
      agent_capability_tools: %{
        "terminal" => ["terminal_list_sessions", "terminal_report_agent_state"]
      }
    ]
  end

  test "filters tools/list to the exact direct grant" do
    tools = [
      %{name: "terminal_list_sessions"},
      %{name: "terminal_send_command"},
      %{name: "invoke_tool"}
    ]

    assert [%{name: "terminal_list_sessions"}] = MCPCapabilityScope.filter_tools(tools, opts())
  end

  test "allows direct grants and denies direct or meta-tool bypasses" do
    assert :ok =
             MCPCapabilityScope.authorize_call(%{"name" => "terminal_list_sessions"}, opts())

    assert {:error, :capability_tool_forbidden} =
             MCPCapabilityScope.authorize_call(%{"name" => "terminal_send_command"}, opts())

    assert {:error, :capability_meta_tool_forbidden} =
             MCPCapabilityScope.authorize_call(
               %{
                 "name" => "invoke_tool",
                 "arguments" => %{"name" => "terminal_send_command", "arguments" => %{}}
               },
               opts()
             )
  end

  test "binds Grok state reports to the issued leader and bundle" do
    good = %{
      "name" => "terminal_report_agent_state",
      "arguments" => %{
        "agent_runtime" => "grok",
        "grok_leader_socket" => "/tmp/#{@claims.leader_id}.sock",
        "grok_bundle_dir" => "/tmp/sha256-#{@claims.bundle_digest}",
        "grok_bundle_digest" => @claims.bundle_digest
      }
    }

    assert :ok = MCPCapabilityScope.authorize_call(good, opts())

    bad = put_in(good, ["arguments", "grok_bundle_digest"], String.duplicate("c", 64))

    assert {:error, :capability_bundle_mismatch} =
             MCPCapabilityScope.authorize_call(bad, opts())
  end

  test "Grok state reports fail closed when leader or bundle proof is omitted" do
    assert {:error, :capability_runtime_mismatch} =
             MCPCapabilityScope.authorize_call(
               %{"name" => "terminal_report_agent_state", "arguments" => %{}},
               opts()
             )

    assert {:error, :capability_bundle_mismatch} =
             MCPCapabilityScope.authorize_call(
               %{
                 "name" => "terminal_report_agent_state",
                 "arguments" => %{"agent_runtime" => "grok"}
               },
               opts()
             )
  end

  test "rejects a terminal tool or worktree report targeting another tmux session" do
    assert {:error, :capability_session_mismatch} =
             MCPCapabilityScope.authorize_call(
               %{
                 "name" => "terminal_list_sessions",
                 "arguments" => %{"session" => "devide_other_agent"}
               },
               opts()
             )

    worktree_opts =
      Keyword.update!(opts(), :agent_capability_tools, fn tools ->
        Map.update!(tools, "terminal", &["terminal_report_worktree" | &1])
      end)

    assert {:error, :capability_session_mismatch} =
             MCPCapabilityScope.authorize_call(
               %{
                 "name" => "terminal_report_worktree",
                 "arguments" => %{"tmux_session_id" => "devide_other_agent"}
               },
               worktree_opts
             )
  end

  test "injects the issued tmux session when a scoped terminal call omits it" do
    assert {:ok, params} =
             MCPCapabilityScope.prepare_call(
               %{
                 "name" => "terminal_report_agent_state",
                 "arguments" => %{
                   "state" => "done",
                   "agent_runtime" => "grok",
                   "grok_leader_socket" => "/tmp/#{@claims.leader_id}.sock",
                   "grok_bundle_dir" => "/tmp/sha256-#{@claims.bundle_digest}",
                   "grok_bundle_digest" => @claims.bundle_digest
                 }
               },
               opts()
             )

    assert params["arguments"]["session"] == @claims.tmux_session_id
    assert params["arguments"]["pane"] == @claims.pane_id

    worktree_opts =
      Keyword.update!(opts(), :agent_capability_tools, fn tools ->
        Map.update!(tools, "terminal", &["terminal_report_worktree" | &1])
      end)

    assert {:ok, params} =
             MCPCapabilityScope.prepare_call(
               %{"name" => "terminal_report_worktree", "arguments" => %{}},
               worktree_opts
             )

    assert params["arguments"]["tmux_session_id"] == @claims.tmux_session_id
  end

  test "legacy non-capability calls remain unchanged" do
    tools = [%{name: "terminal_send_command"}, %{name: "invoke_tool"}]
    assert tools == MCPCapabilityScope.filter_tools(tools, [])
    assert :ok = MCPCapabilityScope.authorize_call(%{"name" => "invoke_tool"}, [])
  end
end
