defmodule DevIdeWeb.API.TerminalMCPTest do
  @moduledoc """
  Protocol-level tests for the terminal-control MCP handler. The handler is
  pure (decoded message in, JSON-RPC outcome out), so these exercise the wire
  contract directly, plus the session-name guardrail that needs no live tmux.
  """
  use ExUnit.Case, async: false

  alias DevIDE.Agents.TerminalTools
  alias DevIDE.Terminals.Tmux
  alias DevIdeWeb.API.TerminalMCP

  test "initialize returns protocol version and server info" do
    assert {:reply, %{jsonrpc: "2.0", id: 1, result: result}} =
             TerminalMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "initialize",
               "params" => %{"protocolVersion" => "2025-03-26"}
             })

    assert result.protocolVersion == "2025-03-26"
    assert result.serverInfo.name =~ "Terminal"
    assert result.capabilities.tools
  end

  test "initialize echoes a supported client protocol version" do
    assert {:reply, %{result: result}} =
             TerminalMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "initialize",
               "params" => %{"protocolVersion" => "2025-06-18"}
             })

    assert result.protocolVersion == "2025-06-18"
  end

  test "initialize falls back to the default version for an unsupported or absent request" do
    for params <- [%{"protocolVersion" => "1999-01-01"}, %{}] do
      assert {:reply, %{result: result}} =
               TerminalMCP.handle(%{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "initialize",
                 "params" => params
               })

      assert result.protocolVersion == "2025-03-26"
    end
  end

  test "initialize explains when the endpoint is pre-scoped" do
    assert {:reply, %{result: result}} =
             TerminalMCP.handle(
               %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"},
               default_workspace_id: "ws-scoped"
             )

    assert result.instructions =~ "pre-scoped"
    assert result.instructions =~ "ws-scoped"
  end

  test "pre-scoped endpoint rejects explicit workspace_id overrides" do
    assert {:reply,
            %{result: %{isError: true, structuredContent: structured, content: [%{text: text}]}}} =
             TerminalMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 7,
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "terminal_list_sessions",
                   "arguments" => %{"workspace_id" => "ws-other"}
                 }
               },
               default_workspace_id: "ws-scoped"
             )

    assert structured["error"] == "workspace_scope_mismatch"
    assert structured["scoped_workspace_id"] == "ws-scoped"
    assert structured["requested_workspace_id"] == "ws-other"
    assert text =~ "Cannot access"
  end

  test "tools/list exposes the narrow terminal tools with inputSchema" do
    assert {:reply, %{result: %{tools: tools}}} =
             TerminalMCP.handle(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

    names = Enum.map(tools, & &1.name)
    assert "terminal_list_sessions" in names
    assert "terminal_topology" in names
    assert "terminal_capture" in names
    assert "terminal_agent_pane" in names
    assert "terminal_capture_agent" in names
    assert "terminal_send_agent_keys" in names
    assert "terminal_send_agent_command" in names
    assert "terminal_send_keys" in names
    assert "terminal_send_command" in names
    assert "annotation_list" in names
    assert "annotation_propose" in names
    assert "terminal_set_agent_label" in names
    assert Enum.all?(tools, &Map.has_key?(&1, :inputSchema))

    capture = Enum.find(tools, &(&1.name == "terminal_capture"))
    props = capture.inputSchema.properties
    assert Map.has_key?(props, :workspace_id)
    assert Map.has_key?(props, :pane)
    assert Map.has_key?(props, :lines)
    assert Map.has_key?(props, :ansi)

    for tool <- ["terminal_send_keys", "terminal_send_command"] do
      spec = Enum.find(tools, &(&1.name == tool))
      assert Map.has_key?(spec.inputSchema.properties, :pane)
    end
  end

  test "ping replies with an empty result" do
    assert {:reply, %{id: 9, result: %{}}} =
             TerminalMCP.handle(%{"jsonrpc" => "2.0", "id" => 9, "method" => "ping"})
  end

  test "notifications produce no reply" do
    assert :noreply =
             TerminalMCP.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
  end

  test "unknown method is a JSON-RPC method-not-found error" do
    assert {:error, %{error: %{code: -32_601}}} =
             TerminalMCP.handle(%{"jsonrpc" => "2.0", "id" => 3, "method" => "frobnicate"})
  end

  test "malformed message is a parse error" do
    assert {:error, %{error: %{code: -32_600}}} = TerminalMCP.handle(%{"not" => "jsonrpc"})
  end

  test "tools/call with a missing session argument reports a structured tool error" do
    assert {:reply,
            %{result: %{isError: true, structuredContent: structured, content: [%{text: text}]}}} =
             TerminalMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 4,
               "method" => "tools/call",
               "params" => %{"name" => "terminal_capture", "arguments" => %{}}
             })

    assert structured["error"] == "missing_argument"
    assert text =~ "session"
  end

  test "tools/call turns bare tool errors into structured tool errors" do
    assert {:reply,
            %{result: %{isError: true, structuredContent: structured, content: [%{text: text}]}}} =
             TerminalMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 44,
               "method" => "tools/call",
               "params" => %{
                 "name" => "terminal_report_worktree",
                 "arguments" => %{"workspace_id" => "ws-tools"}
               }
             })

    assert structured["error"] == "invalid_tool_arguments"
    assert text =~ "invalid_tool_arguments"
  end

  test "tools/call reports ambiguous workspace sessions through structuredContent" do
    prefix = Tmux.workspace_session_prefix("alpha")
    session_a = prefix <> "_a"
    session_b = prefix <> "_b"

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session_a => [%{id: "@1", index: 0, name: "a", active: true, panes: 1, activity: 1}],
      session_b => [%{id: "@1", index: 0, name: "b", active: true, panes: 1, activity: 2}]
    })

    on_exit(fn ->
      Application.delete_env(:dev_ide, :tmux_adapter)
      TmuxCtl.Test.FakeState.delete(:fake_tmux_test_pid)
      TmuxCtl.Test.FakeState.delete(:fake_tmux_windows)
    end)

    assert {:error, %{ambiguous: true, candidate_sessions: candidates}} =
             TerminalTools.invoke("terminal_agent_pane", %{"workspace_id" => "alpha"})

    assert length(candidates) == 2

    assert {:reply,
            %{result: %{isError: true, structuredContent: structured, content: [%{text: text}]}}} =
             TerminalMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 6,
               "method" => "tools/call",
               "params" => %{
                 "name" => "terminal_agent_pane",
                 "arguments" => %{"workspace_id" => "alpha"}
               }
             })

    assert structured["ambiguous"] == true
    assert length(structured["candidate_sessions"]) == 2
    assert text =~ "Multiple workspace sessions"
  end

  test "tools/call rejects a session name outside the devide_ prefix" do
    assert {:reply, %{result: %{isError: true, content: [%{text: text}]}}} =
             TerminalMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 5,
               "method" => "tools/call",
               "params" => %{
                 "name" => "terminal_send_command",
                 "arguments" => %{"session" => "someone-elses-tmux", "command" => "rm -rf /"}
               }
             })

    assert text =~ "unscoped_session"
  end
end
