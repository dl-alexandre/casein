defmodule DevIdeWeb.API.PreviewMCPTest do
  @moduledoc """
  Protocol-level tests for the preview-control MCP handler. The handler is
  pure (decoded message in, JSON-RPC outcome out), so these exercise the wire
  contract directly, plus one real tools/call path through PreviewTools.
  """
  use DevIde.DataCase, async: false

  alias DevIDE.Agents.PreviewTools
  alias DevIDE.PreviewControl.Registry
  alias DevIDE.PreviewPanes
  alias DevIDE.Terminals.Tmux
  alias DevIdeWeb.API.PreviewMCP
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  @v3_workspace %{
    id: "ws-mcp",
    metadata: %{
      type: :v3,
      domain_base: "alice.devbox.example.com",
      ports: %{"app" => 10_100}
    }
  }

  setup do
    prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)
    _ = Registry.clear()
    PreviewPanes.clear()
    seed_workspace_tmux!(@v3_workspace.id)

    on_exit(fn ->
      PreviewPanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      FakeState.delete(:fake_tmux_alive_sessions)

      if is_nil(prev_tmux),
        do: Application.delete_env(:dev_ide, :tmux_adapter),
        else: Application.put_env(:dev_ide, :tmux_adapter, prev_tmux)
    end)

    :ok
  end

  defp seed_workspace_tmux!(workspace_id) do
    session = "#{Tmux.workspace_session_prefix(workspace_id)}default"

    FakeState.put(:fake_tmux_alive_sessions, MapSet.new([session]))

    FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: "/tmp"
        }
      ]
    })
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
    assert "preview_resolve_workspace" in names
    assert "preview_surfaces" in names
    assert "preview_open_current_workspace" in names
    assert "preview_open_app" in names
    assert "preview_open_localhost" in names
    assert "preview_navigate" in names
    assert "preview_observe_pane" in names
    assert "preview_observe" in names
    assert "preview_observe_live" in names
    assert "preview_close" in names
    assert "preview_get_storage" in names
    assert "preview_reload_iframe" in names
    assert "devide_reload_page" in names
    assert Enum.all?(tools, &Map.has_key?(&1, :inputSchema))
  end

  test "scoped endpoint instructions and schemas make workspace_id optional" do
    opts = [default_workspace_id: "ws-scoped"]

    assert {:reply, %{result: init}} =
             PreviewMCP.handle(
               %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"},
               opts
             )

    assert init.instructions =~ "pre-scoped"
    assert init.instructions =~ "ws-scoped"

    assert {:reply, %{result: %{tools: tools}}} =
             PreviewMCP.handle(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}, opts)

    open_app = Enum.find(tools, &(&1.name == "preview_open_app"))
    assert Map.has_key?(open_app.inputSchema.properties, :workspace_id)
    refute "workspace_id" in open_app.inputSchema.required

    reload_page = Enum.find(tools, &(&1.name == "devide_reload_page"))
    assert Map.has_key?(reload_page.inputSchema.properties, :workspace_id)
    refute "workspace_id" in reload_page.inputSchema.required
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
    assert {:error, %{error: %{code: -32_601}}} =
             PreviewMCP.handle(%{"jsonrpc" => "2.0", "id" => 3, "method" => "frobnicate"})
  end

  test "malformed message is a parse error" do
    assert {:error, %{error: %{code: -32_600}}} = PreviewMCP.handle(%{"not" => "jsonrpc"})
  end

  test "tools/call open_app without a workspace_id reports a structured tool error" do
    assert {:reply,
            %{result: %{isError: true, structuredContent: structured, content: [%{text: text}]}}} =
             PreviewMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 4,
               "method" => "tools/call",
               "params" => %{"name" => "preview_open_app", "arguments" => %{}}
             })

    assert structured["error"] == "missing_workspace_id"
    assert text =~ "workspace_id"
  end

  test "tools/call uses default workspace_id when endpoint is scoped" do
    assert {:reply, %{result: %{isError: true, content: [%{text: text}]}}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 4,
                 "method" => "tools/call",
                 "params" => %{"name" => "preview_open_app", "arguments" => %{}}
               },
               default_workspace_id: "ws-scoped"
             )

    refute text =~ "missing_workspace_id"
  end

  test "pre-scoped endpoint rejects explicit workspace_id overrides" do
    assert {:reply,
            %{result: %{isError: true, structuredContent: structured, content: [%{text: text}]}}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 8,
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "preview_surfaces",
                   "arguments" => %{"workspace_id" => "ws-other"}
                 }
               },
               default_workspace_id: "ws-scoped"
             )

    assert structured["error"] == "workspace_scope_mismatch"
    assert structured["scoped_workspace_id"] == "ws-scoped"
    assert structured["requested_workspace_id"] == "ws-other"
    assert text =~ "Omit workspace_id"
    assert text =~ "Cannot access"
  end

  test "pre-scoped endpoint rejects session tools for sessions from another workspace" do
    {:ok, %{session_id: session_id}} =
      PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert {:reply,
            %{result: %{isError: true, structuredContent: structured, content: [%{text: text}]}}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 9,
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "preview_observe",
                   "arguments" => %{"session_id" => session_id}
                 }
               },
               default_workspace_id: "ws-other"
             )

    assert structured["error"] == "workspace_scope_mismatch"
    assert structured["scoped_workspace_id"] == "ws-other"
    assert structured["requested_workspace_id"] == @v3_workspace.id
    assert text =~ "Omit workspace_id"
    assert text =~ "Cannot access"
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

  test "tools/call observe encodes redirect_blocked errors in structuredContent" do
    bypass = Bypass.open()
    port = bypass.port
    previous_adapter = Application.get_env(:dev_ide, :preview_control_adapter)

    Application.put_env(:dev_ide, :preview_control_adapter, :playwright)
    on_exit(fn -> restore_adapter(previous_adapter) end)

    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
      |> Plug.Conn.resp(302, "")
    end)

    workspace =
      update_in(@v3_workspace.metadata, fn metadata ->
        Map.put(metadata, :detected_ports, [port])
      end)

    {:ok, %{session_id: session_id}} =
      PreviewTools.invoke("preview_open_localhost", workspace, %{
        "port" => port,
        "actor_id" => "agent-1"
      })

    assert {:reply,
            %{result: %{isError: true, structuredContent: structured, content: [%{text: text}]}}} =
             PreviewMCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 7,
               "method" => "tools/call",
               "params" => %{
                 "name" => "preview_observe",
                 "arguments" => %{"session_id" => session_id}
               }
             })

    assert structured["error"] == "redirect_blocked"
    assert structured["status"] == 302
    assert structured["location"] =~ "169.254.169.254"
    assert text =~ "Redirect blocked"
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

  defp restore_adapter(nil), do: Application.delete_env(:dev_ide, :preview_control_adapter)

  defp restore_adapter(value), do: Application.put_env(:dev_ide, :preview_control_adapter, value)
end
