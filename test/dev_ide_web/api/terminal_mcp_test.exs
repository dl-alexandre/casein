defmodule DevIdeWeb.API.TerminalMCPTest do
  @moduledoc """
  Protocol-level tests for the terminal-control MCP handler. The handler is
  pure (decoded message in, JSON-RPC outcome out), so these exercise the wire
  contract directly, plus the session-name guardrail that needs no live tmux.
  """
  use ExUnit.Case, async: true

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

  test "tools/list exposes the narrow terminal tools with inputSchema" do
    assert {:reply, %{result: %{tools: tools}}} =
             TerminalMCP.handle(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

    names = Enum.map(tools, & &1.name)
    assert "terminal_list_sessions" in names
    assert "terminal_topology" in names
    assert "terminal_capture" in names
    assert "terminal_send_keys" in names
    assert "terminal_send_command" in names
    assert Enum.all?(tools, &Map.has_key?(&1, :inputSchema))

    capture = Enum.find(tools, &(&1.name == "terminal_capture"))
    props = capture.inputSchema.properties
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

  test "tools/call with a missing session argument reports a tool error" do
    assert {:reply, %{result: %{isError: true, content: [%{text: text}]}}} =
             TerminalMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 4,
               "method" => "tools/call",
               "params" => %{"name" => "terminal_capture", "arguments" => %{}}
             })

    assert text =~ "missing_argument"
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
