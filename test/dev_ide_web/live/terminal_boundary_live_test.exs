defmodule DevIdeWeb.TerminalBoundaryLiveTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Audit
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    bypass = Bypass.open()
    workspace_root = Path.join(System.tmp_dir!(), "devide-terminal-live")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_manager = Application.get_env(:dev_ide, :manager_url)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_default = Application.get_env(:dev_ide, :default_workspace_mode)
    prev_overrides = Application.get_env(:dev_ide, :workspace_modes)

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :default_workspace_mode, :review)
    Application.delete_env(:dev_ide, :workspace_modes)

    MemoryAdapter.clear()
    Audit.clear()

    Bypass.stub(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      File.rm_rf(workspace_root)
      restore(:manager_url, prev_manager)
      restore(:workspaces_root, prev_root)
      restore(:default_workspace_mode, prev_default)
      restore(:workspace_modes, prev_overrides)
    end)

    {:ok, workspace_path: workspace_path}
  end

  test "raw shell surface is hidden until local workspace is manual", %{conn: conn} do
    # Non-manual: the governed terminal hook renders, the raw multi-pane
    # surface (split buttons in the header / mobile keybar) does not.
    {:ok, _view, html} = live(conn, ~p"/workspaces/ws-1?host=local")

    assert html =~ ~s(phx-hook="GhosttyGovernedTerminal")
    refute html =~ ~s(phx-click="split_right")
    refute html =~ ~s(phx-click="split_down")

    {:ok, _} = State.set_mode("ws-1", :manual)

    # Manual + local: the LV mounts directly into raw mode (no chrome
    # button needed — escalation lives in the command palette), so the
    # raw pane surface should render with a focus-able pane div carrying
    # the host id.
    {:ok, view, html} = live(conn, ~p"/workspaces/ws-1?host=local")

    assert html =~ ~s(phx-click="split_right")
    assert html =~ ~s(phx-click="split_down")

    assert has_element?(view, "div[data-host-id=\"local\"][phx-click=\"focus_pane\"]")
  end

  test "manual workspace treats missing or blank host as local for raw shell", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :manual)

    {:ok, no_host_view, _html} = live(conn, ~p"/workspaces/ws-1")
    assert has_element?(no_host_view, "div[data-host-id=\"local\"][phx-click=\"focus_pane\"]")

    {:ok, blank_host_view, _html} = live(conn, "/workspaces/ws-1?host=")
    assert has_element?(blank_host_view, "div[data-host-id=\"local\"][phx-click=\"focus_pane\"]")
  end

  test "mode changes propagate to a mounted LiveView without remount", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/workspaces/ws-1?host=local")

    # Review mode: governed terminal, no raw escalation affordance.
    refute html =~ ~s(id="terminal-mode-raw")

    # Another actor (or this one) flips the workspace to manual; the
    # workspace_mode broadcast must update the mounted view reactively.
    {:ok, _} = State.set_mode("ws-1", :manual)

    assert has_element?(view, "#terminal-mode-raw")

    # And back: the affordance disappears again, no remount involved.
    {:ok, _} = State.set_mode("ws-1", :review)

    refute has_element?(view, "#terminal-mode-raw")
  end

  test "non-local workspace route cannot expose raw shell", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :manual)

    assert {:error, {:live_redirect, %{to: "/workspaces", flash: flash}}} =
             live(conn, ~p"/workspaces/ws-1?host=remote")

    assert flash["error"] =~ "Cross-host attach is not yet configured"
    assert flash["error"] =~ ~s(runtime resolver only honors "local" today)
  end

  defp workspace_payload(conn, workspace_path) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "id" => "ws-1",
        "name" => "alpha",
        "user" => "alice",
        "status" => "running",
        "type" => "v3",
        "branch" => "main",
        "path" => workspace_path
      })
    )
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)
end
