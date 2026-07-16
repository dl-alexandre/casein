defmodule DevIdeWeb.WorkspaceHistoryPanelTest do
  @moduledoc """
  History (previous sessions) side panel inside the workspace cockpit, plus
  the legacy `/workspaces/:id/previous-sessions` redirect. Replaces the tests
  of the removed WorkspaceLive.PreviousSessions full-page LiveView.
  """

  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Agents.{Activity, AgentEvents}
  alias DevIDE.Audit
  alias DevIDE.Labels
  alias DevIDE.Workspaces.State.MemoryAdapter

  @workspace_id "ws-1"
  @workspace_name "alpha"
  @session DevIDE.Terminals.Tmux.session_name(@workspace_name, "api-session")

  setup do
    tmux_prefix = DevIDE.Terminals.Tmux.workspace_session_prefix(@workspace_name)

    kill_tmux_sessions_with_prefix(tmux_prefix)
    MemoryAdapter.clear()
    Audit.clear()
    Activity.clear()
    Labels.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      Activity.clear()
      Labels.clear()
      kill_tmux_sessions_with_prefix(tmux_prefix)
    end)

    :ok
  end

  describe "history side panel" do
    test "lazy-loads: no previous-session search during cockpit mount", %{conn: conn} do
      mount_env!("devide-workspace-history-lazy")
      seed_activity()

      {:ok, view, html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")

      # The panel is not rendered and no history search ran at mount.
      refute html =~ "history-panel"
      refute html =~ "Old compile warning"

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.history_loaded? == false
      assert assigns.history_results == []

      # Opening the tab runs the first (workspace-scoped) search. The cockpit
      # emits its own audit events (db-isolation probe, tmux lifecycle), so the
      # unfiltered count varies — assert the seeded entries instead.
      html = render_click(view, "switch_tab", %{"tab" => "history"})

      assert html =~ "history-panel"
      assert html =~ "Old compile warning"
      assert html =~ "Restart Phoenix preview Bearer [REDACTED]"
      assert html =~ "Queued"
      assert html =~ ~s(id="history-search")
      assert html =~ ~s(phx-debounce="350")
    end

    test "search filters, session deep links, and clear", %{conn: conn} do
      mount_env!("devide-workspace-history-search")
      seed_activity()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
      render_click(view, "switch_tab", %{"tab" => "history"})

      html =
        view
        |> form("#history-search", %{
          "search" => %{
            "query" => "phoenix",
            "workspace" => @workspace_name,
            "source" => "activity",
            "session" => "api-session",
            "pane" => "%3",
            "since" => "2026-06-29",
            "until" => "",
            "limit" => "10"
          }
        })
        |> render_change()

      assert html =~ "1 result"
      assert html =~ "Restart Phoenix preview Bearer [REDACTED]"
      assert html =~ "Queued"
      assert html =~ "Open"
      assert html =~ ~s(href="/workspaces/#{@workspace_id}?)
      assert html =~ "session=#{@session}"
      assert html =~ "pane=%253"
      refute html =~ "Old compile warning"

      html = render_click(view, "history:clear")

      # Cleared filters bring back the unmatched seeded entry (alongside any
      # cockpit-emitted audit noise).
      assert html =~ "Old compile warning"
      assert html =~ "Restart Phoenix preview Bearer [REDACTED]"
    end

    test "refreshes while open when new MCP activity arrives", %{conn: conn} do
      mount_env!("devide-workspace-history-live")

      # Open pre-filtered (query=fresh) so cockpit-emitted audit noise stays out.
      {:ok, view, html} =
        live(conn, ~p"/workspaces/#{@workspace_id}?host=local&tab=history&query=fresh")

      assert html =~ "No matching session context."

      Activity.record(%{
        workspace_id: @workspace_id,
        source: :terminal_mcp,
        tool: "terminal_send_agent_prompt",
        summary: "session=#{@session} pane=%7",
        metadata: %{
          session: @session,
          pane: "%7",
          text: "Fresh agent follow-up",
          status: "done"
        },
        status: :ok,
        inserted_at: ~U[2026-06-29 15:00:00Z]
      })

      html = render(view)

      assert html =~ "Fresh agent follow-up"
      assert html =~ "Done"
      assert html =~ "1 result"
    end

    test "surfaces normalized Grok ACP events while the History panel is open", %{conn: conn} do
      mount_env!("devide-workspace-history-grok-acp")

      {:ok, view, html} =
        live(conn, ~p"/workspaces/#{@workspace_id}?host=local&tab=history&query=permission")

      assert html =~ "No matching session context."

      Activity.record(%{
        workspace_id: @workspace_id,
        source: :grok_acp,
        tool: "grok_permission_request",
        summary: "Permission requested · Execute tests",
        metadata: %{
          session_id: "grok-session-1",
          tool_call_id: "tc-9",
          status: "attention",
          option_count: 2
        },
        status: :ok,
        inserted_at: ~U[2026-06-29 15:30:00Z]
      })

      html = render(view)

      assert html =~ "Permission requested · Execute tests"
      assert html =~ "Attention"
      assert html =~ "grok-session-1"
      assert html =~ "1 result"
    end

    test "hydrates History from durable AgentEvents after the live cache is empty", %{conn: conn} do
      mount_env!("devide-workspace-history-agent-events")

      assert {:ok, _event, :inserted} =
               AgentEvents.append_runtime(%{
                 workspace_id: @workspace_id,
                 producer: "grok",
                 ingress: "acp",
                 agent_session_id: "grok-durable-session",
                 source_event_id: "durable-plan-1",
                 event_type: "plan.updated",
                 summary: "Durable plan restored · 4 steps",
                 payload: %{schema_version: 1, step_count: 4}
               })

      {:ok, _view, html} =
        live(conn, ~p"/workspaces/#{@workspace_id}?host=local&tab=history&query=durable")

      assert html =~ "Durable plan restored · 4 steps"
      assert html =~ "grok-durable-session"
      assert html =~ "1 result"
    end

    test "?tab=history deep link opens the panel and seeds search filters", %{conn: conn} do
      mount_env!("devide-workspace-history-deeplink")
      seed_activity()

      {:ok, _view, html} =
        live(conn, ~p"/workspaces/#{@workspace_id}?host=local&tab=history&query=phoenix")

      assert html =~ "history-panel"
      assert html =~ "1 result"
      assert html =~ "Restart Phoenix preview Bearer [REDACTED]"
      refute html =~ "Old compile warning"
    end

    test "renders compact preview context for preview MCP activity", %{conn: conn} do
      mount_env!("devide-workspace-history-preview")

      Activity.record(%{
        workspace_id: @workspace_id,
        source: :preview_mcp,
        tool: "preview_screenshot",
        summary: "preview_screenshot · session preview-123",
        metadata: %{
          "agent_session" => @session,
          "agent_pane" => "%3",
          "session_id" => "preview-123",
          "pane_id" => "%8",
          "preview_title" => "Dashboard",
          "display_url" => "/preview-proxy/ws-1/5173/dashboard",
          "screenshot_url" => "/preview-artifacts/ws-1/snap.png",
          "recording_url" => "/preview-artifacts/ws-1/rec.webm",
          "status" => "done"
        },
        status: :ok,
        inserted_at: ~U[2026-06-29 16:00:00Z]
      })

      {:ok, _view, html} =
        live(
          conn,
          ~p"/workspaces/#{@workspace_id}?host=local&tab=history&query=snap.png&source=preview"
        )

      assert html =~ "1 result"
      assert html =~ "Preview"
      assert html =~ "preview_screenshot"
      assert html =~ @session
      assert html =~ "%3"
      assert html =~ "Dashboard"
      assert html =~ "/preview-proxy/ws-1/5173/dashboard"
      assert html =~ "/preview-artifacts/ws-1/rec.webm"
      assert html =~ "/preview-artifacts/ws-1/snap.png"
    end
  end

  describe "legacy /workspaces/:id/previous-sessions redirect" do
    test "redirects to the workspace URL with the history deep link", %{conn: conn} do
      conn = get(conn, "/workspaces/#{@workspace_id}/previous-sessions")

      assert redirected_to(conn) == "/workspaces/#{@workspace_id}?tab=history"
    end

    test "preserves the old page's search query params", %{conn: conn} do
      conn =
        get(
          conn,
          "/workspaces/#{@workspace_id}/previous-sessions?query=phoenix&source=activity&session=api-session"
        )

      location = redirected_to(conn)
      %URI{path: path, query: query} = URI.parse(location)

      assert path == "/workspaces/#{@workspace_id}"

      assert URI.decode_query(query) == %{
               "tab" => "history",
               "query" => "phoenix",
               "source" => "activity",
               "session" => "api-session"
             }
    end
  end

  # --- helpers -----------------------------------------------------------------

  # Cockpit mount environment: workspaces root on disk + manager status stub.
  defp mount_env!(root_basename) do
    workspace_root = Path.join(System.tmp_dir!(), root_basename)
    workspace_path = Path.join(workspace_root, @workspace_id)
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Req.Test.stub(DevIDE.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", @workspace_id, "status"]} =
          conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => @workspace_id,
            "name" => @workspace_name,
            "user" => "dev",
            "status" => "running",
            "type" => "v3",
            "branch" => "main",
            "path" => workspace_path
          })
        )

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)
  end

  defp seed_activity do
    Activity.record(%{
      workspace_id: @workspace_id,
      source: :terminal_mcp,
      tool: "terminal_send_agent_prompt",
      summary: "session=#{@session} pane=%4",
      metadata: %{
        session: @session,
        pane: "%4",
        text: "Old compile warning"
      },
      status: :ok,
      inserted_at: ~U[2026-06-28 10:00:00Z]
    })

    Activity.record(%{
      workspace_id: @workspace_id,
      source: :terminal_mcp,
      tool: "terminal_send_agent_prompt",
      summary: "session=#{@session} pane=%3",
      metadata: %{
        session: @session,
        pane: "%3",
        text: "Restart Phoenix preview Bearer abc123",
        status: :queued
      },
      status: :ok,
      inserted_at: ~U[2026-06-29 12:00:00Z]
    })
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)

  defp kill_tmux_sessions_with_prefix(prefix) when is_binary(prefix) do
    with executable when is_binary(executable) <- System.find_executable("tmux"),
         {sessions, 0} <-
           System.cmd(
             executable,
             DevIDE.Terminals.TmuxServer.args() ++ ["list-sessions", "-F", "\#{session_name}"],
             stderr_to_stdout: true
           ) do
      sessions
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.each(fn session ->
        _ =
          System.cmd(
            executable,
            DevIDE.Terminals.TmuxServer.args() ++ ["kill-session", "-t", session],
            stderr_to_stdout: true
          )
      end)
    else
      _ -> :ok
    end

    :ok
  end
end
