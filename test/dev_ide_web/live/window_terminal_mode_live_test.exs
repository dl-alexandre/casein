defmodule DevIdeWeb.WindowTerminalModeLiveTest do
  @moduledoc """
  Per-tmux-window raw/governed mode memory, UI badges, and sessionStorage restore.
  """
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Audit
  alias DevIDE.Workspaces.State

  setup do
    bypass = Bypass.open()
    workspace_root = Path.join(System.tmp_dir!(), "devide-window-mode-live")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_manager = Application.get_env(:dev_ide, :manager_url)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "alpha-#{System.unique_integer([:positive])}"
    tmux_session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev")
    activity_now = DateTime.utc_now() |> DateTime.to_unix()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{
          id: "@0",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: activity_now,
          current_command: "bash"
        },
        %{
          id: "@1",
          index: 1,
          name: "agents",
          active: false,
          panes: 1,
          activity: activity_now,
          current_command: "bash"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        %{
          id: "%0",
          window_id: "@0",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: workspace_path,
          activity: activity_now,
          activity_flag: false,
          bell: false,
          unseen_changes: false
        },
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
          current_path: workspace_path,
          activity: activity_now,
          activity_flag: false,
          bell: false,
          unseen_changes: false
        }
      ]
    })

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path, workspace_name)
    end)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:manager_url, prev_manager)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
    end)

    {:ok, workspace_name: workspace_name, tmux_session: tmux_session}
  end

  test "governed workspace remembers raw shell per tmux window", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :review)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :governed

    view
    |> element("#terminal-mode-raw")
    |> render_click()

    assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :raw
    assert %{"@0" => :raw} = :sys.get_state(view.pid).socket.assigns.window_terminal_modes

    assert has_element?(view, ~s([data-raw-window="true"]))

    render_click(view, "tmux:select_window", %{"window-id" => "@1"})
    assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :governed

    render_click(view, "tmux:select_window", %{"window-id" => "@0"})
    assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :raw
  end

  test "manual workspace keeps governed preference on a window that exited raw", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :manual)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :raw

    view
    |> element("#terminal-mode-governed")
    |> render_click()

    assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :governed
    assert %{"@0" => :governed} = :sys.get_state(view.pid).socket.assigns.window_terminal_modes

    render_click(view, "tmux:select_window", %{"window-id" => "@1"})
    assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :raw

    render_click(view, "tmux:select_window", %{"window-id" => "@0"})
    assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :governed
  end

  test "restore_window_modes event merges sessionStorage payload", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :review)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    render_click(view, "terminal:restore_window_modes", %{"modes" => %{"@0" => "raw"}})

    assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :raw
    assert %{"@0" => :raw} = :sys.get_state(view.pid).socket.assigns.window_terminal_modes
  end

  test "manual workspace shows gov badge on window that exited raw", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :manual)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    view
    |> element("#terminal-mode-governed")
    |> render_click()

    assert has_element?(view, ~s([data-gov-window="true"]))
  end

  test "restore_window_modes accepts full payload with names and new_windows_raw", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :review)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    render_click(view, "terminal:restore_window_modes", %{
      "modes" => %{"@0" => "raw"},
      "names" => %{"agents" => "governed"},
      "new_windows_raw" => true
    })

    state = :sys.get_state(view.pid).socket.assigns
    assert state.terminal_mode == :raw
    assert %{"@0" => :raw} = state.window_terminal_modes
    assert %{"agents" => :governed} = state.window_terminal_mode_names
    assert state.new_windows_default_raw? == true
  end

  test "new windows default raw preference applies to unseen windows", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :review)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    render_click(view, "terminal:set_new_windows_default_raw", %{"enabled" => "true"})

    assert :sys.get_state(view.pid).socket.assigns.new_windows_default_raw? == true

    render_click(view, "tmux:select_window", %{"window-id" => "@1"})
    assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :raw
  end

  test "url mode=raw deep link enters raw when allowed", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :review)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local&mode=raw")
    await_mount_hydration(view)

    assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :raw
  end

  test "switching to raw window shows info flash", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :review)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    render_click(view, "terminal:set_mode", %{"mode" => "raw"})
    render_click(view, "tmux:select_window", %{"window-id" => "@1"})
    render_click(view, "tmux:select_window", %{"window-id" => "@0"})

    assert render(view) =~ "Window &quot;shell&quot; is raw shell"
  end

  test "audit drawer filters events by tmux window name", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :review)
    Audit.clear()

    on_exit(fn -> Audit.clear() end)

    Audit.emit!(%{
      action: "terminal.raw_entered",
      workspace_id: "ws-1",
      metadata: %{"tmux_window_name" => "shell"}
    })

    Audit.emit!(%{
      action: "terminal.raw_entered",
      workspace_id: "ws-1",
      metadata: %{"tmux_window_name" => "agents"}
    })

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    render_click(view, "audit_drawer:toggle", %{})
    html = render(view)
    assert html =~ "win:shell"
    assert html =~ "win:agents"

    view
    |> element("#audit-window-filter")
    |> render_change(%{filter: "agents"})

    html = render(view)
    assert html =~ "win:agents"
    refute html =~ "win:shell"
  end

  test "renaming a tmux window migrates remembered mode by name", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :manual)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    render_click(view, "tmux:select_window", %{"window-id" => "@1"})
    render_click(view, "terminal:set_mode", %{"mode" => "governed"})

    assert %{"@1" => :governed} =
             :sys.get_state(view.pid).socket.assigns.window_terminal_modes

    render_click(view, "tmux:rename_window", %{"id" => "@1", "name" => "verify"})

    names = :sys.get_state(view.pid).socket.assigns.window_terminal_mode_names
    assert names["verify"] == :governed
    refute Map.has_key?(names, "agents")
  end

  test "palette labels name the active tmux window", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :review)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    render_hook(view, "palette:open", %{})

    labels =
      :sys.get_state(view.pid).socket.assigns.palette_items
      |> Enum.map(& &1.label)

    assert Enum.any?(labels, &String.contains?(&1, "window: shell"))
  end

  defp await_mount_hydration(view) do
    render_async(view, 5_000)
  end

  defp workspace_payload(conn, workspace_path, workspace_name) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "id" => "ws-1",
        "name" => workspace_name,
        "user" => "dev",
        "status" => "running",
        "type" => "v3",
        "branch" => "main",
        "path" => workspace_path
      })
    )
  end

  @fake_state_keys ~w(fake_tmux_windows fake_tmux_panes fake_tmux_test_pid)a

  defp restore(k, v) when k in @fake_state_keys, do: TmuxCtl.Test.FakeState.restore(k, v)
  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)
end
