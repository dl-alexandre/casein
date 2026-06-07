defmodule DevIdeWeb.API.PreviewMCPTest do
  @moduledoc """
  Protocol-level tests for the preview-control MCP handler. The handler is
  pure (decoded message in, JSON-RPC outcome out), so these exercise the wire
  contract directly, plus one real tools/call path through PreviewTools.
  """
  use DevIde.DataCase, async: false

  alias DevIDE.Agents.PreviewTools
  alias DevIDE.PreviewControl.Registry
  alias DevIdeWeb.API.PreviewMCP

  @v3_workspace %{
    id: "ws-mcp",
    metadata: %{
      type: :v3,
      domain_base: "alice.devbox.example.com",
      ports: %{"app" => 10_100}
    }
  }

  setup do
    _ = Registry.clear()
    :ok
  end

  test "initialize returns protocol version and server info" do
    assert {:reply, %{jsonrpc: "2.0", id: 1, result: result}} =
             PreviewMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "initialize",
               "params" => %{"protocolVersion" => "2025-03-26"}
             })

    assert result.protocolVersion == "2025-03-26"
    assert result.serverInfo.name =~ "Preview"
    assert result.capabilities.tools
  end

  test "tools/list exposes the narrow preview tools with inputSchema" do
    assert {:reply, %{result: %{tools: tools}}} =
             PreviewMCP.handle(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

    names = Enum.map(tools, & &1.name)
    assert "preview_open_app" in names
    assert "preview_observe" in names
    assert "preview_close" in names
    assert Enum.all?(tools, &Map.has_key?(&1, :inputSchema))
  end

  test "ping replies with an empty result" do
    assert {:reply, %{id: 9, result: %{}}} =
             PreviewMCP.handle(%{"jsonrpc" => "2.0", "id" => 9, "method" => "ping"})
  end

  test "notifications produce no reply" do
    assert :noreply =
             PreviewMCP.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
  end

  test "unknown method is a JSON-RPC method-not-found error" do
    assert {:error, %{error: %{code: -32601}}} =
             PreviewMCP.handle(%{"jsonrpc" => "2.0", "id" => 3, "method" => "frobnicate"})
  end

  test "malformed message is a parse error" do
    assert {:error, %{error: %{code: -32600}}} = PreviewMCP.handle(%{"not" => "jsonrpc"})
  end

  test "tools/call open_app without a workspace_id reports a tool error" do
    assert {:reply, %{result: %{isError: true, content: [%{text: text}]}}} =
             PreviewMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 4,
               "method" => "tools/call",
               "params" => %{"name" => "preview_open_app", "arguments" => %{}}
             })

    assert text =~ "missing_workspace_id"
  end

  test "tools/call observe runs against an open session" do
    {:ok, %{session_id: session_id}} =
      PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert {:reply, %{result: result}} =
             PreviewMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 5,
               "method" => "tools/call",
               "params" => %{
                 "name" => "preview_observe",
                 "arguments" => %{"session_id" => session_id}
               }
             })

    refute result[:isError]
    assert %{structuredContent: %{"url" => url}} = result
    assert url =~ "alice.devbox.example.com"
  end

  test "tools/call close closes an open session" do
    {:ok, %{session_id: session_id}} =
      PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert {:reply, %{result: result}} =
             PreviewMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 6,
               "method" => "tools/call",
               "params" => %{
                 "name" => "preview_close",
                 "arguments" => %{"session_id" => session_id}
               }
             })

    refute result[:isError]
    assert %{structuredContent: %{"session_id" => ^session_id, "status" => "closed"}} = result

    assert {:error, :not_found} =
             PreviewTools.invoke("preview_observe", @v3_workspace, %{"session_id" => session_id})
  end
end
