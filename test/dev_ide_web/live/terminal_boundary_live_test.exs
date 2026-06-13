defmodule DevIdeWeb.TerminalBoundaryLiveTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Audit
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    bypass = Bypass.open()
    unique = System.unique_integer([:positive])
    workspace_id = "ws-#{unique}"
    workspace_name = "alpha-#{unique}"
    workspace_root = Path.join(System.tmp_dir!(), "devide-terminal-live-#{unique}")

    workspace_path = Path.join(workspace_root, workspace_id)
    File.mkdir_p!(workspace_path)
    {_out, 0} = System.cmd("git", ["init", "--quiet"], cd: workspace_path)
    File.write!(Path.join(workspace_path, "README.md"), "# #{workspace_name}\n")
    {_out, 0} = System.cmd("git", ["add", "README.md"], cd: workspace_path)

    {_out, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=DevIDE Test",
          "-c",
          "user.email=devide-test@example.invalid",
          "commit",
          "--quiet",
          "-m",
          "initial"
        ],
        cd: workspace_path
      )

    prev_manager = Application.get_env(:dev_ide, :manager_url)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_default = Application.get_env(:dev_ide, :default_workspace_mode)
    prev_overrides = Application.get_env(:dev_ide, :workspace_modes)
    prev_pane_backend = Application.get_env(:dev_ide, :ghostty_pane_backend)

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :default_workspace_mode, :review)
    Application.put_env(:dev_ide, :ghostty_pane_backend, :ghostty_pty)
    Application.delete_env(:dev_ide, :workspace_modes)

    MemoryAdapter.clear()
    Audit.clear()

    Bypass.stub(bypass, "GET", "/api/workspaces/#{workspace_id}/status", fn conn ->
      workspace_payload(conn, workspace_id, workspace_path, workspace_name)
    end)

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      File.rm_rf(workspace_root)
      restore(:manager_url, prev_manager)
      restore(:workspaces_root, prev_root)
      restore(:default_workspace_mode, prev_default)
      restore(:workspace_modes, prev_overrides)
      restore(:ghostty_pane_backend, prev_pane_backend)
    end)

    {:ok, workspace_id: workspace_id, workspace_path: workspace_path}
  end

  test "raw shell surface is hidden until local workspace is manual", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    # Non-manual: the governed terminal hook renders, the raw multi-pane
    # surface (split buttons in the header / mobile keybar) does not.
    {:ok, _view, html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    assert html =~ ~s(phx-hook="GhosttyGovernedTerminal")
    refute html =~ ~s(phx-click="split_right")
    refute html =~ ~s(phx-click="split_down")

    {:ok, _} = State.set_mode(workspace_id, :manual)

    # Manual + local: the LV mounts directly into raw mode (no chrome
    # button needed — escalation lives in the command palette), so the raw
    # Ghostty surface should render once tmux topology is available.
    {:ok, _view, html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    assert html =~ ~s(phx-click="split_right")
    assert html =~ ~s(phx-click="split_down")
  end

  test "manual workspace treats missing or blank host as local for raw shell", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, _} = State.set_mode(workspace_id, :manual)

    {:ok, _no_host_view, no_host_html} = live(conn, ~p"/workspaces/#{workspace_id}")

    assert no_host_html =~ ~s(phx-click="split_right")
    assert no_host_html =~ ~s(phx-click="split_down")

    {:ok, _blank_host_view, blank_host_html} = live(conn, "/workspaces/#{workspace_id}?host=")

    assert blank_host_html =~ ~s(phx-click="split_right")
    assert blank_host_html =~ ~s(phx-click="split_down")
  end

  test "picker preview event replies without crashing and rejects foreign sessions", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, _} = State.set_mode(workspace_id, :manual)
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    # Same-workspace target (the attached session): handled, view stays alive.
    render_click(view, "terminal:picker_preview", %{"window-id" => "@1"})
    # Foreign session prefix: validation refuses the capture, still no crash.
    render_click(view, "terminal:picker_preview", %{"tmux-session" => "devide_other-ws_u-x"})

    assert Process.alive?(view.pid)
  end

  test "mode changes propagate to a mounted LiveView without remount", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    # Review mode: governed terminal, no raw escalation affordance.
    refute html =~ ~s(id="terminal-mode-raw")

    # Another actor (or this one) flips the workspace to manual; the
    # workspace_mode broadcast must update the mounted view reactively.
    {:ok, _} = State.set_mode(workspace_id, :manual)

    assert has_element?(view, "#terminal-mode-raw")

    # And back: the affordance disappears again, no remount involved.
    {:ok, _} = State.set_mode(workspace_id, :review)

    refute has_element?(view, "#terminal-mode-raw")
  end

  test "non-local workspace route cannot expose raw shell", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, _} = State.set_mode(workspace_id, :manual)

    assert {:error, {:live_redirect, %{to: "/workspaces", flash: flash}}} =
             live(conn, ~p"/workspaces/#{workspace_id}?host=remote")

    assert flash["error"] =~ "Cross-host attach is not yet configured"
    assert flash["error"] =~ ~s(runtime resolver only honors "local" today)
  end

  defp workspace_payload(conn, workspace_id, workspace_path, workspace_name) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "id" => workspace_id,
        "name" => workspace_name,
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
