defmodule DevIdeWeb.WorkspaceLive.PreviousSessionsTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Agents.Activity
  alias DevIDE.Audit
  alias DevIDE.Workspaces.State.MemoryAdapter

  @session DevIDE.Terminals.Tmux.session_name("alpha", "api-session")

  setup do
    bypass = Bypass.open()
    prev_manager_url = Application.get_env(:dev_ide, :manager_url)

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")

    MemoryAdapter.clear()
    Audit.clear()
    Activity.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      Activity.clear()

      if prev_manager_url,
        do: Application.put_env(:dev_ide, :manager_url, prev_manager_url),
        else: Application.delete_env(:dev_ide, :manager_url)
    end)

    {:ok, bypass: bypass}
  end

  test "renders a debounced previous-session search UI with bounded filters", %{
    conn: conn,
    bypass: bypass
  } do
    stub_workspace(bypass)
    seed_activity()

    {:ok, view, html} = live(conn, ~p"/workspaces/ws-1/previous-sessions")

    assert html =~ "Previous Sessions"
    assert html =~ "Restart Phoenix preview Bearer [REDACTED]"
    assert html =~ "Old compile warning"
    assert html =~ "Queued"
    assert html =~ "2 results"
    assert html =~ ~s(id="previous-sessions-search")
    assert html =~ ~s(phx-debounce="350")
    assert html =~ "Workspace"
    assert html =~ "Source"

    html =
      view
      |> form("#previous-sessions-search", %{
        "search" => %{
          "query" => "phoenix",
          "workspace" => "alpha",
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
    assert html =~ ~s(href="/workspaces/ws-1?)
    assert html =~ "session=devide_alpha_api-session"
    assert html =~ "pane=%253"
    refute html =~ "Old compile warning"

    html = render_click(view, "clear")

    assert html =~ "2 results"
    assert html =~ "Old compile warning"
  end

  test "refreshes when new MCP activity arrives", %{conn: conn, bypass: bypass} do
    stub_workspace(bypass)

    {:ok, view, html} = live(conn, ~p"/workspaces/ws-1/previous-sessions?query=fresh")

    assert html =~ "No matching session context."

    Activity.record(%{
      workspace_id: "ws-1",
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

  test "renders compact preview context for preview MCP activity", %{conn: conn, bypass: bypass} do
    stub_workspace(bypass)

    Activity.record(%{
      workspace_id: "ws-1",
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
      live(conn, ~p"/workspaces/ws-1/previous-sessions?query=snap.png&source=preview")

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

  test "shows a clear missing-workspace state", %{conn: conn, bypass: bypass} do
    Bypass.stub(bypass, "GET", "/api/workspaces/missing/status", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, _view, html} = live(conn, ~p"/workspaces/missing/previous-sessions")

    assert html =~ "Workspace not found."
  end

  defp seed_activity do
    Activity.record(%{
      workspace_id: "ws-1",
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
      workspace_id: "ws-1",
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

  defp stub_workspace(bypass) do
    Bypass.stub(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "ws-1",
          "name" => "alpha",
          "user" => "dev",
          "status" => "running",
          "type" => "v3",
          "branch" => "main",
          "path" => "/data/workspaces/alice/alpha"
        })
      )
    end)
  end
end
