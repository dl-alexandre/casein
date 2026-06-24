defmodule DevIdeWeb.API.PreviewMCPTest.Source do
  @behaviour DevIDE.WorkspaceSource

  alias DevIDE.Workspace

  @workspace %Workspace{
    id: "ws-mcp",
    name: "ws-mcp",
    user: "alice",
    branch: "main",
    status: :running,
    path: "/tmp/ws-mcp",
    metadata: %{
      type: :v3,
      domain_base: "alice.devbox.example.com",
      ports: %{"app" => 10_100}
    }
  }

  def list(_opts, _auth), do: {:ok, [workspace()]}
  def get("ws-mcp", _auth), do: {:ok, workspace()}
  def get(_id, _auth), do: {:error, :not_found}
  def create(_params, _auth), do: {:error, :not_implemented}
  def start(_id, _auth), do: {:error, :not_implemented}
  def stop(_id, _auth), do: {:error, :not_implemented}
  def delete(_id, _opts, _auth), do: {:error, :not_implemented}
  def stream_logs(_id, _service, _pid), do: {:error, :not_implemented}
  def safe_host_path(%{path: path}) when is_binary(path) and path != "", do: {:ok, path}
  def safe_host_path(_workspace), do: {:error, :missing_path}

  def safe_host_loc(workspace),
    do: with({:ok, path} <- safe_host_path(workspace), do: {:ok, {:local, path}})

  defp workspace do
    Application.get_env(:dev_ide, :preview_mcp_test_workspace, @workspace)
  end
end

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
  alias DevIDE.Runtimes
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Test.RuntimeSeed
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter
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
    prev_source = Application.get_env(:dev_ide, :workspace_source)
    prev_test_workspace = Application.get_env(:dev_ide, :preview_mcp_test_workspace)
    prev_preflight = Application.get_env(:dev_ide, :preview_open_preflight)
    MemoryAdapter.clear()
    Runtimes.clear()
    Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)
    Application.put_env(:dev_ide, :workspace_source, DevIdeWeb.API.PreviewMCPTest.Source)
    _ = Registry.clear()
    PreviewPanes.clear()
    File.mkdir_p!("/tmp/ws-mcp")
    seed_workspace_record!()
    seed_workspace_tmux!(@v3_workspace.id)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      PreviewPanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      FakeState.delete(:fake_tmux_alive_sessions)
      FakeState.delete(:fake_tmux_scrollback)

      if is_nil(prev_tmux),
        do: Application.delete_env(:dev_ide, :tmux_adapter),
        else: Application.put_env(:dev_ide, :tmux_adapter, prev_tmux)

      if is_nil(prev_source),
        do: Application.delete_env(:dev_ide, :workspace_source),
        else: Application.put_env(:dev_ide, :workspace_source, prev_source)

      if is_nil(prev_test_workspace),
        do: Application.delete_env(:dev_ide, :preview_mcp_test_workspace),
        else: Application.put_env(:dev_ide, :preview_mcp_test_workspace, prev_test_workspace)

      if is_nil(prev_preflight),
        do: Application.delete_env(:dev_ide, :preview_open_preflight),
        else: Application.put_env(:dev_ide, :preview_open_preflight, prev_preflight)
    end)

    :ok
  end

  defp seed_workspace_record! do
    {:ok, _record} =
      State.sync(%Workspace{
        id: @v3_workspace.id,
        name: @v3_workspace.id,
        user: "alice",
        branch: "main",
        status: :running,
        path: "/tmp/ws-mcp",
        metadata: @v3_workspace.metadata
      })
  end

  defp seed_workspace_tmux!(workspace_id, opts \\ []) do
    session = Keyword.get(opts, :session, "#{Tmux.workspace_session_prefix(workspace_id)}default")
    pane_id = Keyword.get(opts, :pane_id, "%1")
    activity = Keyword.get(opts, :activity, 0)

    alive =
      FakeState.get(:fake_tmux_alive_sessions, MapSet.new())
      |> MapSet.put(session)

    FakeState.put(:fake_tmux_alive_sessions, alive)

    windows =
      FakeState.get(:fake_tmux_windows, %{})
      |> Map.put(session, [
        %{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: activity}
      ])

    FakeState.put(:fake_tmux_windows, windows)

    panes =
      FakeState.get(:fake_tmux_panes, %{})
      |> Map.put(session, [
        %{
          id: pane_id,
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
      ])

    FakeState.put(:fake_tmux_panes, panes)

    FakeState.update(:fake_tmux_scrollback, %{}, fn scrollback ->
      Map.put(scrollback, {session, pane_id}, "# DevIDE agent pane\n")
    end)
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
    assert "preview_open" in names
    # Deprecated aliases stay listed so existing agent configs keep working.
    assert "preview_open_current_workspace" in names
    assert "preview_open_here" in names
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

    open = Enum.find(tools, &(&1.name == "preview_open"))
    assert open.metadata["mutation"] == true
    assert open.metadata["danger_level"] == "medium"
    assert "preview_control" in open.metadata["capabilities"]
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

  test "session-scoped endpoint injects tmux_session for preview opens" do
    worktree_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}wt-agent"
    seed_runtime_surface!(worktree_session, 4101)

    seed_workspace_tmux!(@v3_workspace.id,
      session: worktree_session,
      pane_id: "%10",
      activity: 50
    )

    assert {:reply, %{result: result}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 40,
                 "method" => "tools/call",
                 "params" => %{"name" => "preview_open_app", "arguments" => %{}}
               },
               default_workspace_id: @v3_workspace.id,
               default_tmux_session: worktree_session
             )

    refute result[:isError]
    pane_id = result.structuredContent["pane_id"]
    registration = PreviewPanes.get_by_pane(pane_id)
    assert registration.tmux_session == worktree_session
    assert registration.url == "http://localhost:4101"
  end

  test "preview_open (mode app) opens the app surface like preview_open_app" do
    worktree_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}wt-open"
    seed_runtime_surface!(worktree_session, 4109)

    seed_workspace_tmux!(@v3_workspace.id,
      session: worktree_session,
      pane_id: "%11",
      activity: 50
    )

    assert {:reply, %{result: result}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 41,
                 "method" => "tools/call",
                 "params" => %{"name" => "preview_open", "arguments" => %{"mode" => "app"}}
               },
               default_workspace_id: @v3_workspace.id,
               default_tmux_session: worktree_session
             )

    refute result[:isError]
    registration = PreviewPanes.get_by_pane(result.structuredContent["pane_id"])
    assert registration.url == "http://localhost:4109"
  end

  test "preview_open rejects an unknown mode with a structured error" do
    assert {:reply, %{result: %{isError: true, structuredContent: structured}}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 42,
                 "method" => "tools/call",
                 "params" => %{"name" => "preview_open", "arguments" => %{"mode" => "bogus"}}
               },
               default_workspace_id: @v3_workspace.id
             )

    assert structured["error"] == "invalid_mode"
    assert structured["mode"] == "bogus"
    assert "app" in structured["allowed_modes"]
  end

  test "preview_open mode here without a tmux_session reports the missing-session error" do
    assert {:reply, %{result: %{isError: true, content: [%{text: text}]}}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 43,
                 "method" => "tools/call",
                 "params" => %{"name" => "preview_open", "arguments" => %{"mode" => "here"}}
               },
               default_workspace_id: @v3_workspace.id
             )

    assert text =~ "tmux_session"
  end

  test "session-scoped endpoint injects tmux_session for preview_open_here" do
    worktree_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}wt-agent"

    seed_workspace_tmux!(@v3_workspace.id,
      session: worktree_session,
      pane_id: "%10",
      activity: 50
    )

    seed_runtime_surface!(worktree_session, 5173)

    assert {:reply, %{result: result}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 42,
                 "method" => "tools/call",
                 "params" => %{"name" => "preview_open_here", "arguments" => %{}}
               },
               default_workspace_id: @v3_workspace.id,
               default_tmux_session: worktree_session
             )

    refute result[:isError]
    pane_id = result.structuredContent["pane_id"]
    registration = PreviewPanes.get_by_pane(pane_id)
    assert registration.tmux_session == worktree_session
    assert registration.url == "http://localhost:5173"
  end

  test "session-scoped endpoint injects tmux_session for preview_surfaces" do
    worktree_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}wt-agent"
    seed_runtime_surface!(worktree_session, 4101, runtime_id: "rt-preview")

    assert {:reply, %{result: result}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 45,
                 "method" => "tools/call",
                 "params" => %{"name" => "preview_surfaces", "arguments" => %{}}
               },
               default_workspace_id: @v3_workspace.id,
               default_tmux_session: worktree_session
             )

    refute result[:isError]
    [first | _] = result.structuredContent["surfaces"]
    assert first["source"] == "runtime"
    assert first["runtime_id"] == "rt-preview"
    assert first["surface_key"] == "runtime:rt-preview:app"
    assert first["url"] == "http://localhost:4101"
  end

  test "preview_open_here reports structured error without tmux_session" do
    assert {:reply,
            %{result: %{isError: true, structuredContent: structured, content: [%{text: text}]}}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 43,
                 "method" => "tools/call",
                 "params" => %{"name" => "preview_open_here", "arguments" => %{}}
               },
               default_workspace_id: @v3_workspace.id
             )

    assert structured["error"] == "missing_tmux_session"
    assert text =~ "session-scoped Preview MCP URL"
    assert text =~ "tmux_session"
  end

  test "unscoped preview_open_app reports ambiguous tmux sessions" do
    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    default_session = "#{prefix}default"
    worktree_session = "#{prefix}wt-agent"

    seed_workspace_tmux!(@v3_workspace.id,
      session: worktree_session,
      pane_id: "%10",
      activity: 50
    )

    assert {:reply,
            %{result: %{isError: true, structuredContent: structured, content: [%{text: text}]}}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 44,
                 "method" => "tools/call",
                 "params" => %{"name" => "preview_open_app", "arguments" => %{}}
               },
               default_workspace_id: @v3_workspace.id
             )

    assert structured["error"] == "ambiguous_tmux_session"
    assert structured["ambiguous"] == true
    assert default_session in structured["candidate_session_names"]
    assert worktree_session in structured["candidate_session_names"]
    assert text =~ "Multiple tmux sessions"
  end

  test "worktree-scoped preview opens the worktree server in the worktree tmux session" do
    base_server = Bypass.open()
    worktree_server = Bypass.open()
    request_counts = start_supervised!({Agent, fn -> %{base: 0, worktree: 0} end})

    stub_preview_server(base_server, request_counts, :base)
    stub_preview_server(worktree_server, request_counts, :worktree)
    Application.put_env(:dev_ide, :preview_open_preflight, true)

    workspace =
      %Workspace{
        id: @v3_workspace.id,
        name: @v3_workspace.id,
        user: "alice",
        branch: "main",
        status: :running,
        path: "/tmp/ws-mcp",
        metadata:
          @v3_workspace.metadata
          |> Map.put(:ports, %{"app" => base_server.port})
          |> Map.put(
            :terminal_output,
            "base server http://localhost:#{base_server.port}/\n" <>
              "worktree server http://localhost:#{worktree_server.port}/\n"
          )
          |> Map.put(:detected_ports, [base_server.port, worktree_server.port])
      }

    Application.put_env(:dev_ide, :preview_mcp_test_workspace, workspace)

    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    base_session = "#{prefix}default"
    worktree_session = "#{prefix}wt-agent"

    seed_workspace_tmux!(@v3_workspace.id,
      session: worktree_session,
      pane_id: "%10",
      activity: 50
    )

    seed_runtime_surface!(worktree_session, worktree_server.port, runtime_id: "rt-worktree")

    assert {:reply,
            %{result: %{isError: true, structuredContent: structured, content: [%{text: text}]}}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 45,
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "preview_open_app",
                   "arguments" => %{}
                 }
               },
               default_workspace_id: @v3_workspace.id
             )

    assert structured["error"] == "ambiguous_tmux_session"
    assert structured["ambiguous"] == true
    assert base_session in structured["candidate_session_names"]
    assert worktree_session in structured["candidate_session_names"]
    assert text =~ "Multiple tmux sessions"
    assert PreviewPanes.list_for_workspace(@v3_workspace.id) == []
    assert pane_count(base_session) == 1
    assert pane_count(worktree_session) == 1
    assert request_count(request_counts, :base) == 0
    assert request_count(request_counts, :worktree) == 0

    assert {:reply, %{result: worktree_result}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 46,
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "preview_open_here",
                   "arguments" => %{}
                 }
               },
               default_workspace_id: @v3_workspace.id,
               default_tmux_session: worktree_session
             )

    refute worktree_result[:isError]
    worktree_url = "http://localhost:#{worktree_server.port}"
    base_url = "http://localhost:#{base_server.port}/"
    worktree_pane_id = worktree_result.structuredContent["pane_id"]
    worktree_registration = PreviewPanes.get_by_pane(worktree_pane_id)

    assert worktree_result.structuredContent["current_url"] == worktree_url
    assert worktree_result.structuredContent["display_url"] == worktree_url
    assert worktree_registration.tmux_session == worktree_session
    assert worktree_registration.url == worktree_url
    assert worktree_registration.display_url == worktree_url
    refute worktree_registration.url == base_url
    assert pane_count(base_session) == 1
    assert pane_count(worktree_session) == 2
    assert request_count(request_counts, :base) == 0
    assert request_count(request_counts, :worktree) > 0

    assert {:reply, %{result: base_result}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 47,
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "preview_open_localhost",
                   "arguments" => %{
                     "port" => base_server.port,
                     "tmux_session" => base_session
                   }
                 }
               },
               default_workspace_id: @v3_workspace.id
             )

    refute base_result[:isError]
    base_pane_id = base_result.structuredContent["pane_id"]
    base_registration = PreviewPanes.get_by_pane(base_pane_id)

    assert base_result.structuredContent["current_url"] == base_url
    assert base_registration.tmux_session == base_session
    assert base_registration.url == base_url
    assert pane_count(base_session) == 2
    assert pane_count(worktree_session) == 2
    assert request_count(request_counts, :base) > 0
  end

  test "session-scoped endpoint rejects explicit tmux_session overrides" do
    scoped_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}wt-agent"
    other_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert {:reply,
            %{result: %{isError: true, structuredContent: structured, content: [%{text: text}]}}} =
             PreviewMCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 41,
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "preview_open_app",
                   "arguments" => %{"tmux_session" => other_session}
                 }
               },
               default_workspace_id: @v3_workspace.id,
               default_tmux_session: scoped_session
             )

    assert structured["error"] == "tmux_session_scope_mismatch"
    assert structured["scoped_tmux_session"] == scoped_session
    assert structured["requested_tmux_session"] == other_session
    assert text =~ "pre-scoped to tmux_session"
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

    Bypass.expect(bypass, "GET", "/", fn conn ->
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

  defp stub_preview_server(bypass, request_counts, key) when key in [:base, :worktree] do
    Bypass.stub(bypass, "GET", "/", fn conn ->
      Agent.update(request_counts, &Map.update!(&1, key, fn count -> count + 1 end))

      Plug.Conn.resp(conn, 200, "#{key} preview")
    end)
  end

  defp seed_runtime_surface!(tmux_session, port, opts \\ []) do
    runtime_id = Keyword.get(opts, :runtime_id, "rt-preview")

    RuntimeSeed.seed_runtime!(@v3_workspace.id,
      runtime_id: runtime_id,
      status: "provisioned",
      tmux_session_id: tmux_session,
      worktree_path: "/tmp/ws-mcp/#{runtime_id}",
      runtime_profile: %{
        "name" => "custom",
        "ports" => %{"app" => port},
        "surfaces" => [%{"name" => "app", "port" => port}]
      }
    )
  end

  defp request_count(request_counts, key) when key in [:base, :worktree] do
    Agent.get(request_counts, &Map.fetch!(&1, key))
  end

  defp pane_count(tmux_session) do
    FakeState.get(:fake_tmux_panes, %{})
    |> Map.get(tmux_session, [])
    |> length()
  end

  defp restore_adapter(nil), do: Application.delete_env(:dev_ide, :preview_control_adapter)

  defp restore_adapter(value), do: Application.put_env(:dev_ide, :preview_control_adapter, value)
end
