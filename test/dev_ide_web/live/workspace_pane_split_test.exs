defmodule DevIdeWeb.WorkspacePaneSplitTest do
  @moduledoc """
  End-to-end coverage of the multi-pane refactor in
  `DevIdeWeb.WorkspaceLive.Show`. Exercises the pane-mutation event
  handlers (`split_right`, `split_down`, `close_pane`, tmux pane select) via
  `Phoenix.LiveViewTest.render_click/2`, which routes through
  `handle_event/3` exactly like a browser click would.

  Setup mirrors `DevIdeWeb.TerminalBoundaryLiveTest`: Bypass-stubbed
  workspace payload, `MemoryAdapter` for State, and `:manual` mode so the raw
  Ghostty path renders the split buttons.

  Each browser pane owns its own tmux session, so splits are pure layout
  mutations + a new `PaneWorker` that runs `tmux new-session` for the new
  pane. Tests that require tmux are tagged `@tag :tmux` and skipped when
  the binary is missing.
  """
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Audit
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  @tmux_available System.find_executable("tmux") != nil

  setup do
    bypass = Bypass.open()
    workspace_root = Path.join(System.tmp_dir!(), "devide-pane-split-live")
    workspace_path = Path.join(workspace_root, "ws-1")
    workspace_name = "alpha-#{System.unique_integer([:positive, :monotonic])}"
    workspace_tmux_prefix = DevIDE.Terminals.Tmux.workspace_session_prefix(workspace_name)
    File.mkdir_p!(workspace_path)

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

    Bypass.stub(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path, workspace_name)
    end)

    # Manual mode + local host enables the Ghostty raw multi-pane surface
    # which is what we want to exercise.
    {:ok, _} = State.set_mode("ws-1", :manual)

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      kill_tmux_sessions_with_prefix(workspace_tmux_prefix)
      File.rm_rf(workspace_root)
      restore(:manager_url, prev_manager)
      restore(:workspaces_root, prev_root)
      restore(:default_workspace_mode, prev_default)
      restore(:workspace_modes, prev_overrides)
      restore(:ghostty_pane_backend, prev_pane_backend)
    end)

    {:ok, workspace_name: workspace_name, workspace_path: workspace_path}
  end

  describe "initial pane state" do
    test "raw mode seeds one Ghostty attachment and exposes tmux split controls", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/workspaces/ws-1")

      assert html =~ ~s(phx-click="split_right")
      assert html =~ ~s(phx-click="split_down")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.terminal_mode == :raw
      assert map_size(assigns.pane_data) == 1
      assert Map.has_key?(assigns.pane_data, "pane-1")
      assert assigns.focused_pane_id == "pane-1"
      assert assigns.pane_data["pane-1"].session_sid == assigns.terminal_sid
      assert assigns.pane_data["pane-1"].backend in [nil, :ghostty_pty]

      # Before tmux topology arrives, raw mode renders a fullscreen Ghostty host.
      assert has_element?(
               view,
               ~s(#ghostty-pane-1[phx-hook="GhosttyTerminal"][phx-update="ignore"])
             )

      refute has_element?(view, "#pane-wrapper-pane-1")
    end

    test "shell session tabs keep raw mode and retarget the primary pane", %{
      conn: conn,
      workspace_name: workspace_name,
      workspace_path: workspace_path
    } do
      prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
      prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
      prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
      prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

      current_session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev")
      extra_sid = "u-dev-extra"
      extra_session = DevIDE.Terminals.Tmux.session_name(workspace_name, extra_sid)
      activity_now = DateTime.utc_now() |> DateTime.to_unix()

      Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        current_session => [
          %{
            id: "@0",
            index: 0,
            name: "shell",
            active: true,
            panes: 1,
            activity: activity_now,
            current_command: "bash"
          }
        ],
        extra_session => [
          %{
            id: "@0",
            index: 0,
            name: "extra",
            active: true,
            panes: 1,
            activity: activity_now,
            current_command: "bash"
          }
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        current_session => [raw_test_pane("%0", workspace_path, activity_now)],
        extra_session => [raw_test_pane("%0", workspace_path, activity_now)]
      })

      on_exit(fn ->
        restore(:tmux_adapter, prev_tmux_adapter)
        restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
        restore(:fake_tmux_windows, prev_fake_tmux_windows)
        restore(:fake_tmux_panes, prev_fake_tmux_panes)
      end)

      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
      await_mount_hydration(view)

      assert has_element?(view, ~s([phx-value-session-id="#{extra_sid}"]))

      # Terminals are raw everywhere now.
      assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :raw
      assert has_element?(view, "#terminal-mode-raw")

      view
      |> element("#active_sessions-#{extra_sid}")
      |> render_click()

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.terminal_mode == :raw
      assert assigns.terminal_sid == extra_sid
      assert assigns.tmux_session == extra_session
      assert map_size(assigns.pane_data) == 1
      assert assigns.pane_data["pane-1"].session_sid == extra_sid
      assert assigns.pane_data["pane-1"].tmux_session == extra_session

      assert has_element?(view, "#ghostty-pane-1[phx-hook=\"GhosttyTerminal\"]")

      # Still raw after the session switch.
      assert has_element?(view, "#terminal-mode-raw")
    end
  end

  describe "split buttons drive real tmux splits" do
    # Splits are tmux-native: the buttons run `split-window` against the
    # attached session's active pane (same as C-b % / C-b "), and the browser
    # keeps a single attachment — no LiveView-side panes are created.
    test "split_right / split_down call tmux split-window on the active pane", %{
      conn: conn,
      workspace_name: workspace_name,
      workspace_path: workspace_path
    } do
      prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
      prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
      prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
      prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

      session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev")
      activity_now = DateTime.utc_now() |> DateTime.to_unix()

      Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [
          %{
            id: "@0",
            index: 0,
            name: "shell",
            active: true,
            panes: 1,
            activity: activity_now,
            current_command: "bash"
          }
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [raw_test_pane("%0", workspace_path, activity_now)]
      })

      on_exit(fn ->
        restore(:tmux_adapter, prev_tmux_adapter)
        restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
        restore(:fake_tmux_windows, prev_fake_tmux_windows)
        restore(:fake_tmux_panes, prev_fake_tmux_panes)
      end)

      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
      await_mount_hydration(view)

      Phoenix.LiveViewTest.render_click(view, "split_right")
      assert_receive {:fake_tmux_split_pane, ^session, "%0", "h", new_pane_id}

      assigns = :sys.get_state(view.pid).socket.assigns
      assert map_size(assigns.pane_data) == 1
      # The topology refresh picked up the tmux-side pane.
      assert Enum.any?(assigns.tmux_panes, &(&1.id == new_pane_id))

      # Raw mode keeps the tmux-native geometry overlay and adds a second tile.
      assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='#{new_pane_id}']")
      assert has_element?(view, ~s([data-pane-id="#{new_pane_id}"]))

      # tmux focuses the new pane after a split; split_down targets it.
      Phoenix.LiveViewTest.render_click(view, "split_down")
      assert_receive {:fake_tmux_split_pane, ^session, ^new_pane_id, "v", _}
    end

    test "zoom, navigate, equalize, and close drive tmux on the active pane", %{
      conn: conn,
      workspace_name: workspace_name,
      workspace_path: workspace_path
    } do
      prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
      prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
      prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
      prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

      session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev")
      activity_now = DateTime.utc_now() |> DateTime.to_unix()

      Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [
          %{
            id: "@0",
            index: 0,
            name: "shell",
            active: true,
            panes: 2,
            activity: activity_now,
            current_command: "bash"
          }
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [
          raw_test_pane("%0", workspace_path, activity_now),
          %{
            raw_test_pane("%1", workspace_path, activity_now)
            | active: false,
              index: 1,
              left: 60
          }
        ]
      })

      on_exit(fn ->
        restore(:tmux_adapter, prev_tmux_adapter)
        restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
        restore(:fake_tmux_windows, prev_fake_tmux_windows)
        restore(:fake_tmux_panes, prev_fake_tmux_panes)
      end)

      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
      await_mount_hydration(view)

      # Raw mode with 2+ tmux panes renders clickable geometry tiles (not a
      # single fullscreen terminal). Clicking another shell tile moves tmux
      # focus so keyboard input follows the selected pane.
      assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%0']")
      assert has_element?(view, "#tmux-pane--1[phx-click='tmux:select_pane']")
      refute has_element?(view, "#tmux-pane--0[phx-click='tmux:select_pane']")

      view
      |> element("#tmux-pane--1")
      |> render_click()

      assert_receive {:fake_tmux_select_pane, ^session, "%1"}
      assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%1']")

      # Zoom toggles tmux resize-pane -Z on the active pane (C-b z).
      Phoenix.LiveViewTest.render_click(view, "pane:zoom_focused")
      assert_receive {:fake_tmux_zoom_pane, ^session, "%1"}

      # focus_next / nav:dir are tmux select-pane.
      Phoenix.LiveViewTest.render_click(view, "pane:focus_next")
      assert_receive {:fake_tmux_navigate_pane, ^session, "n"}

      render_hook(view, "nav:dir", %{"dir" => "left"})
      assert_receive {:fake_tmux_navigate_pane, ^session, "L"}

      # Equalize applies a tmux layout preset to the window.
      Phoenix.LiveViewTest.render_click(view, "equalize_layout")
      assert_receive {:fake_tmux_select_layout, ^session, "tiled"}

      # close_others kills everything but the active pane in the window.
      Phoenix.LiveViewTest.render_click(view, "pane:close_others")
      assert_receive {:fake_tmux_kill_other_panes, ^session, "%1"}

      # With a single pane left in the only window of the only session,
      # close replaces the window (open a fresh one, kill the old) rather than
      # refusing — C-b x never strands the operator.
      Phoenix.LiveViewTest.render_click(view, "pane:close_focused")
      assert_receive {:fake_tmux_new_window, ^session, _}
      assert_receive {:fake_tmux_kill_window, ^session, "@0"}
      refute_receive {:fake_tmux_kill_pane, ^session, _}, 50
    end

    test "close_focused decides against live tmux, not a stale cached pane count", %{
      conn: conn,
      workspace_name: workspace_name,
      workspace_path: workspace_path
    } do
      prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
      prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
      prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
      prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

      session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev")
      activity_now = DateTime.utc_now() |> DateTime.to_unix()

      Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [
          %{
            id: "@0",
            index: 0,
            name: "shell",
            active: true,
            panes: 2,
            activity: activity_now,
            current_command: "bash"
          }
        ]
      })

      # Live tmux has TWO panes in the active window.
      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [
          raw_test_pane("%0", workspace_path, activity_now),
          %{
            raw_test_pane("%1", workspace_path, activity_now)
            | active: false,
              index: 1,
              left: 60
          }
        ]
      })

      on_exit(fn ->
        restore(:tmux_adapter, prev_tmux_adapter)
        restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
        restore(:fake_tmux_windows, prev_fake_tmux_windows)
        restore(:fake_tmux_panes, prev_fake_tmux_panes)
      end)

      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
      await_mount_hydration(view)

      # Simulate a stale LiveView: its cached topology lags reality and only
      # remembers a single pane (e.g. a degraded socket missed the split
      # broadcast). The pre-fix guard trusted this and refused the close.
      :sys.replace_state(view.pid, fn lv_state ->
        socket = lv_state.socket
        one_pane = Enum.take(socket.assigns.tmux_panes, 1)

        new_socket =
          Phoenix.Component.assign(socket,
            tmux_panes: one_pane,
            active_window_pane_count: 1
          )

        %{lv_state | socket: new_socket}
      end)

      # Close re-reads tmux (2 panes) and proceeds, killing the active pane,
      # instead of wrongly flashing "Cannot close the last pane".
      Phoenix.LiveViewTest.render_click(view, "pane:close_focused")
      assert_receive {:fake_tmux_kill_pane, ^session, "%0"}
    end

    test "close_focused on a single-pane window closes the window when others exist", %{
      conn: conn,
      workspace_name: workspace_name,
      workspace_path: workspace_path
    } do
      prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
      prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
      prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
      prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

      session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev")
      activity_now = DateTime.utc_now() |> DateTime.to_unix()

      Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

      # Two windows, the active one (@0) holding a single pane.
      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [
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
            name: "logs",
            active: false,
            panes: 1,
            activity: activity_now,
            current_command: "bash"
          }
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [
          raw_test_pane("%0", workspace_path, activity_now),
          %{
            raw_test_pane("%1", workspace_path, activity_now)
            | active: false,
              window_id: "@1"
          }
        ]
      })

      on_exit(fn ->
        restore(:tmux_adapter, prev_tmux_adapter)
        restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
        restore(:fake_tmux_windows, prev_fake_tmux_windows)
        restore(:fake_tmux_panes, prev_fake_tmux_panes)
      end)

      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
      await_mount_hydration(view)

      # tmux closes a window when its final pane dies; C-b x on a single-pane
      # tab closes the tab rather than refusing, since another window survives.
      Phoenix.LiveViewTest.render_click(view, "pane:close_focused")
      assert_receive {:fake_tmux_kill_window, ^session, "@0"}
      refute_receive {:fake_tmux_kill_pane, ^session, _}, 50
    end

    test "close_focused on the last window closes it and drops into another session", %{
      conn: conn,
      workspace_name: workspace_name,
      workspace_path: workspace_path
    } do
      prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
      prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
      prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
      prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

      session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev")
      activity_now = DateTime.utc_now() |> DateTime.to_unix()

      Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

      # Single window, single pane: closing it ends the tmux session.
      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [
          %{
            id: "@0",
            index: 0,
            name: "shell",
            active: true,
            panes: 1,
            activity: activity_now,
            current_command: "bash"
          }
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [raw_test_pane("%0", workspace_path, activity_now)]
      })

      on_exit(fn ->
        restore(:tmux_adapter, prev_tmux_adapter)
        restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
        restore(:fake_tmux_windows, prev_fake_tmux_windows)
        restore(:fake_tmux_panes, prev_fake_tmux_panes)
      end)

      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
      await_mount_hydration(view)

      # Pretend a second session exists in the bar so there is somewhere to land.
      :sys.replace_state(view.pid, fn lv_state ->
        socket = lv_state.socket
        current = socket.assigns.terminal_sid
        fallback_id = "fallback-#{current}"

        fallback = %{
          id: fallback_id,
          dom_id: "active_sessions-#{fallback_id}",
          kind: :shell,
          label: fallback_id,
          detail: "",
          title: fallback_id,
          cwd: nil,
          tmux_session: DevIDE.Terminals.Tmux.session_name(workspace_name, fallback_id),
          windows: [],
          window_count: 0,
          quiet_count: 0,
          pane_ids: [],
          preview_count: 0,
          activity_state: :idle,
          activity_class: "",
          activity_label: ""
        }

        tabs = (socket.assigns[:session_tabs] || []) ++ [fallback]
        %{lv_state | socket: Phoenix.Component.assign(socket, :session_tabs, tabs)}
      end)

      # Last window of the session: close it (ending the session) rather than
      # refuse, because another session is available to switch into.
      Phoenix.LiveViewTest.render_click(view, "pane:close_focused")
      assert_receive {:fake_tmux_kill_window, ^session, "@0"}
      refute_receive {:fake_tmux_kill_pane, ^session, _}, 50
    end
  end

  describe "PTY data routing (no tmux required)" do
    test "{:pty_data, pane_id, data} is a no-op when ghostty_term is nil", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
      await_mount_hydration(view)

      # The LV now eagerly starts the Ghostty worker on mount in raw mode (so the
      # prompt is visible on first paint). Let that async start settle first so it
      # cannot re-populate the handles after we nil them out below.
      await_mount_hydration(view)
      await_pane_worker(view, "pane-1")

      # Explicitly nil out pane-1's handles to exercise the no-op branch.
      :sys.replace_state(view.pid, fn lv_state ->
        socket = lv_state.socket

        pane_data =
          Map.update!(socket.assigns.pane_data, "pane-1", fn p ->
            %{p | ghostty_term: nil, ghostty_pty: nil, worker: nil, error: nil}
          end)

        new_socket = Phoenix.Component.assign(socket, :pane_data, pane_data)
        %{lv_state | socket: new_socket}
      end)

      assigns_before = :sys.get_state(view.pid).socket.assigns
      assert assigns_before.pane_data["pane-1"].ghostty_term == nil

      # Synthesize a PTY data message. The handler should look up the
      # pane, see ghostty_term == nil, fall through to the catch-all
      # clause, and return {:noreply, socket} without crashing.
      ref = Process.monitor(view.pid)
      send(view.pid, {:pty_data, "pane-1", "hello from a phantom PTY"})

      # The handler is synchronous. Force a round-trip to make sure the
      # message was processed before we assert liveness.
      _ = :sys.get_state(view.pid)

      refute_receive {:DOWN, ^ref, :process, _, _}, 100
      assert Process.alive?(view.pid)
      Process.demonitor(ref, [:flush])

      # State should be unchanged.
      assigns_after = :sys.get_state(view.pid).socket.assigns
      assert assigns_after.pane_data == assigns_before.pane_data
      assert assigns_after.focused_pane_id == assigns_before.focused_pane_id
    end

    test "{:pty_data, ...} for an unknown pane id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
      await_mount_hydration(view)

      ref = Process.monitor(view.pid)
      send(view.pid, {:pty_data, "pane-does-not-exist", "anything"})
      _ = :sys.get_state(view.pid)

      refute_receive {:DOWN, ^ref, :process, _, _}, 100
      assert Process.alive?(view.pid)
      Process.demonitor(ref, [:flush])
    end

    test "{:pty_exit, pane_id, _status} clears pty/worker fields without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
      await_mount_hydration(view)

      # Let the eager mount-time Ghostty worker finish starting so the pty_exit
      # handler is what clears the handles (not a worker that starts afterwards).
      await_mount_hydration(view)
      await_pane_worker(view, "pane-1")

      ref = Process.monitor(view.pid)
      send(view.pid, {:pty_exit, "pane-1", :process_died})
      _ = :sys.get_state(view.pid)

      refute_receive {:DOWN, ^ref, :process, _, _}, 100
      assert Process.alive?(view.pid)
      Process.demonitor(ref, [:flush])

      pane = :sys.get_state(view.pid).socket.assigns.pane_data["pane-1"]
      assert pane.ghostty_pty == nil
      assert pane.worker == nil
    end
  end

  describe "{:pty_exit, ...} handler clears the pane handles" do
    test "ghostty_term, ghostty_pty, worker are set to nil (and pending refresh dropped)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
      await_mount_hydration(view)

      # Let the eager mount-time worker settle so the pty_exit handler is what
      # sets the error/clears the handles (not a worker starting afterwards and
      # resetting error: nil).
      await_mount_hydration(view)
      await_pane_worker(view, "pane-1")

      # The handler path for a known pane exercises update_pane + pending cleanup.
      ref = Process.monitor(view.pid)
      send(view.pid, {:pty_exit, "pane-1", :process_died})
      _ = :sys.get_state(view.pid)

      refute_receive {:DOWN, ^ref, :process, _, _}, 100
      assert Process.alive?(view.pid)
      Process.demonitor(ref, [:flush])

      pane = :sys.get_state(view.pid).socket.assigns.pane_data["pane-1"]
      assert pane.ghostty_term == nil
      assert pane.ghostty_pty == nil
      assert pane.worker == nil
      assert pane.error == :process_died
      # Also exercises our #1 change: the pending set stays valid (no KeyError).
      pending =
        Map.get(:sys.get_state(view.pid).socket.assigns, :pane_refresh_pending, MapSet.new())

      refute MapSet.member?(pending, "pane-1")
    end

    test "clean shell exits do not auto-reattach", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
      await_mount_hydration(view)

      await_mount_hydration(view)
      await_pane_worker(view, "pane-1")

      ref = Process.monitor(view.pid)
      send(view.pid, {:pty_exit, "pane-1", 0})
      _ = :sys.get_state(view.pid)

      refute_receive {:DOWN, ^ref, :process, _, _}, 100
      assert Process.alive?(view.pid)
      Process.demonitor(ref, [:flush])

      pane = :sys.get_state(view.pid).socket.assigns.pane_data["pane-1"]
      assert pane.error == 0
      assert pane.auto_retry_count == 0
    end

    test "erlexec exit-status tuples are normalized before storing pane errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
      await_mount_hydration(view)

      await_mount_hydration(view)
      await_pane_worker(view, "pane-1")

      ref = Process.monitor(view.pid)
      send(view.pid, {:pty_exit, "pane-1", {:exit_status, 256}})
      _ = :sys.get_state(view.pid)

      refute_receive {:DOWN, ^ref, :process, _, _}, 100
      assert Process.alive?(view.pid)
      Process.demonitor(ref, [:flush])

      pane = :sys.get_state(view.pid).socket.assigns.pane_data["pane-1"]
      assert pane.error == 256
      assert pane.auto_retry_count == 0
    end
  end

  describe "PaneWorker direct round-trip (Fix #2 wiring)" do
    @tag :tmux
    test "worker tags PTY output as {:pty_data, pane_id, data} and forwards writes",
         %{conn: _conn} do
      unless @tmux_available do
        IO.warn("tmux not available — skipping PaneWorker round-trip test")
        :ok
      else
        pane_id = "pane-worker-test-1"

        session =
          "devide-pw-test-" <>
            Integer.to_string(System.unique_integer([:positive, :monotonic]))

        # Cold start — kill any stray session from a prior run.
        _ = System.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)

        on_exit(fn ->
          _ = System.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)
        end)

        {:ok, worker} =
          DevIdeWeb.WorkspaceLive.PaneWorker.start_link(
            parent: self(),
            pane_id: pane_id,
            tmux_session: session,
            backend: :ghostty_pty,
            cols: 80,
            rows: 24
          )

        {term, pty} = DevIdeWeb.WorkspaceLive.PaneWorker.get_handles(worker)
        assert is_pid(term) and Process.alive?(term)
        assert is_pid(pty) and Process.alive?(pty)

        send(worker, {:term_data, make_ref(), "session-frame"})
        assert_pty_data_contains(pane_id, "session-frame", 5_000)

        send(worker, {:term_data, make_ref(), "session-replay", :replay})
        assert_pty_data_contains(pane_id, "session-replay", 5_000)

        # Write a known sequence to the PTY. Output gets tagged by the
        # worker as {:pty_data, pane_id, data} before reaching us.
        :ok = Ghostty.PTY.write(pty, "echo hello\n")

        # tmux echoes the command + result; assert we get a tagged frame
        # carrying *our* pane_id within 2s.
        assert_receive {:pty_data, ^pane_id, data1}, 8_000
        assert is_binary(data1)

        # Bare {:data, _} must NOT have leaked through — the worker is
        # supposed to retag everything.
        refute_received {:data, _}

        # Forward a {:pty_write, ...} into the worker — the worker should
        # relay it into *this* pane's PTY without crashing. We then poke
        # the PTY again and confirm we keep receiving tagged data
        # (i.e. the worker survived).
        send(worker, {:pty_write, "ping"})

        :ok = Ghostty.PTY.write(pty, "echo done\n")
        assert_receive {:pty_data, ^pane_id, _data2}, 8_000

        assert Process.alive?(worker), "worker died after {:pty_write, _}"

        # Stop the worker; drain any tail messages from the PTY, then
        # confirm no more {:pty_data, ...} arrives.
        # PaneWorker uses start_link (so it's linked to *us*); unlink
        # before stopping so the :shutdown reason doesn't kill the test.
        Process.unlink(worker)
        ref = Process.monitor(worker)
        GenServer.stop(worker, :shutdown)
        assert_receive {:DOWN, ^ref, :process, _, _}, 1_000

        # Drain whatever was in flight before/at shutdown.
        drain_pty_data(pane_id, 200)

        refute_receive {:pty_data, ^pane_id, _}, 300
      end
    end

    test "shared-session backend uses one canonical session process for IO and resize" do
      pane_id = "pane-worker-shared"

      {:ok, worker} =
        DevIdeWeb.WorkspaceLive.PaneWorker.start_link(
          parent: self(),
          pane_id: pane_id,
          tmux_session: "ignored-by-shared-backend",
          workspace_key: "alpha",
          session_sid: "u-dev",
          loc: {:fake, self()},
          backend: :shared_session,
          session_module: DevIDE.Test.FakeTerminalSession,
          cols: 80,
          rows: 24
        )

      assert_receive {:fake_session_subscribed, session_pid, ^worker, "alpha", "u-dev"}, 1_000

      {term, backend_pid} = DevIdeWeb.WorkspaceLive.PaneWorker.get_handles(worker)
      assert is_pid(term) and Process.alive?(term)
      assert backend_pid == session_pid

      send(worker, {:pty_write, "echo shared\n"})
      assert_receive {:fake_session_input, ^session_pid, "echo shared\n"}, 1_000
      assert_pty_data_contains(pane_id, "echo shared\n", 5_000)

      :ok = DevIdeWeb.WorkspaceLive.PaneWorker.resize(worker, 100, 32)
      assert_receive {:fake_session_resize, ^session_pid, 100, 32}, 1_000

      Process.unlink(worker)
      ref = Process.monitor(worker)
      GenServer.stop(worker, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^worker, :shutdown}, 1_000
      assert_receive {:fake_session_unsubscribed, ^session_pid, ^worker}, 1_000
    end

    test "session-owner backend uses the canonical owner boundary for IO and resize" do
      pane_id = "pane-worker-owner"

      {:ok, worker} =
        DevIdeWeb.WorkspaceLive.PaneWorker.start_link(
          parent: self(),
          pane_id: pane_id,
          tmux_session: "ignored-by-owner-backend",
          workspace_id: "ws-1",
          workspace_key: "alpha",
          session_sid: "u-dev",
          loc: {:local, "/tmp"},
          host_id: "local",
          backend: :session_owner,
          terminal_module: DevIDE.Test.FakeTerminals,
          test_owner: self(),
          cols: 80,
          rows: 24
        )

      assert_receive {:fake_owner_attached, owner_pid, ^worker, "ws-1", info, opts}, 1_000
      assert info.kind == :shell
      assert info.workspace_id == "ws-1"
      assert info.sid == "u-dev"
      assert opts[:workspace_key] == "alpha"
      assert opts[:mode] == :raw

      {term, backend_pid} = DevIdeWeb.WorkspaceLive.PaneWorker.get_handles(worker)
      assert is_pid(term) and Process.alive?(term)
      assert backend_pid == owner_pid

      send(worker, {:pty_write, "owner-boundary\n"})
      assert_receive {:fake_owner_input, ^owner_pid, "owner-boundary\n"}, 1_000
      assert_pty_data_contains(pane_id, "owner-boundary\n", 5_000)

      send(worker, {:pty_write, "\eP>|libghostty\e\\"})
      refute_receive {:fake_owner_input, ^owner_pid, "\eP>|libghostty\e\\"}, 250

      send(worker, {:pty_write, "\e[?62;22c\e[>1;0;0c"})
      refute_receive {:fake_owner_input, ^owner_pid, "\e[?62;22c\e[>1;0;0c"}, 250

      :ok = DevIdeWeb.WorkspaceLive.PaneWorker.resize(worker, 132, 44)
      assert_receive {:fake_owner_resize, ^owner_pid, 132, 44}, 1_000

      Process.unlink(worker)
      ref = Process.monitor(worker)
      GenServer.stop(worker, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^worker, :shutdown}, 1_000
      assert_receive {:fake_owner_detached, ^owner_pid, ^worker}, 1_000
    end
  end

  defp drain_pty_data(pane_id, timeout_ms) do
    receive do
      {:pty_data, ^pane_id, _} -> drain_pty_data(pane_id, timeout_ms)
    after
      timeout_ms -> :ok
    end
  end

  # The worker coalesces PTY chunks into one binary per flush window, so an
  # expected sequence may arrive merged with neighbouring output (shell
  # prompt bytes, a preceding frame). Accumulate pty_data until the expected
  # substring shows up instead of pattern-matching whole messages.
  defp assert_pty_data_contains(pane_id, substring, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_pty_data_contains(pane_id, substring, "", deadline)
  end

  defp do_assert_pty_data_contains(pane_id, substring, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:pty_data, ^pane_id, data} when is_binary(data) ->
        acc = acc <> data

        if String.contains?(acc, substring) do
          :ok
        else
          do_assert_pty_data_contains(pane_id, substring, acc, deadline)
        end
    after
      remaining ->
        flunk(
          "expected pty_data for #{inspect(pane_id)} containing #{inspect(substring)}; " <>
            "received so far: #{inspect(acc)}"
        )
    end
  end

  defp await_mount_hydration(view) do
    render_async(view, 5_000)
  end

  # The mount-time eager Ghostty worker start is async; poll until the pane has
  # live handles (or give up) so tests that nil/clear those handles aren't raced
  # by a worker that starts afterwards.
  defp await_pane_worker(view, pane_id, attempts \\ 50)

  defp await_pane_worker(_view, _pane_id, 0), do: :ok

  defp await_pane_worker(view, pane_id, attempts) do
    pane = :sys.get_state(view.pid).socket.assigns.pane_data[pane_id]

    if pane && is_pid(pane[:ghostty_pty]) do
      :ok
    else
      Process.sleep(20)
      await_pane_worker(view, pane_id, attempts - 1)
    end
  end

  defp workspace_payload(conn, workspace_path, workspace_name) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "id" => "ws-1",
        "name" => workspace_name,
        "user" => "alice",
        "status" => "running",
        "type" => "v3",
        "branch" => "main",
        "path" => workspace_path
      })
    )
  end

  defp raw_test_pane(id, workspace_path, activity) do
    %{
      id: id,
      window_id: "@0",
      index: 0,
      active: true,
      left: 0,
      top: 0,
      width: 120,
      height: 40,
      current_command: "bash",
      current_path: workspace_path,
      activity: activity,
      activity_flag: false,
      bell: false,
      unseen_changes: false
    }
  end

  @fake_state_keys ~w(fake_tmux_windows fake_tmux_panes fake_tmux_test_pid)a

  defp restore(k, v) when k in @fake_state_keys, do: TmuxCtl.Test.FakeState.restore(k, v)
  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)

  defp kill_tmux_session(session) when is_binary(session) do
    _ = System.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)
    :ok
  end

  defp kill_tmux_session(_), do: :ok

  defp kill_tmux_sessions_with_prefix(prefix) when is_binary(prefix) do
    with true <- @tmux_available,
         {sessions, 0} <- System.cmd("tmux", ["list-sessions", "-F", "\#{session_name}"]) do
      sessions
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.each(&kill_tmux_session/1)
    else
      _ -> :ok
    end

    :ok
  end

  defp kill_tmux_sessions_with_prefix(_), do: :ok

  describe "command palette" do
    test "open seeds items, defaults selection to first, nav wraps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

      render_hook(view, "palette:open", %{})

      st = :sys.get_state(view.pid).socket.assigns
      assert st.palette_open == true
      assert st.palette_selected_idx == 0
      assert st.palette_items != [], "expected default palette items on open"

      total = length(st.palette_items)

      # Down advances by one.
      render_hook(view, "palette:nav", %{"dir" => "down"})
      assert :sys.get_state(view.pid).socket.assigns.palette_selected_idx == 1

      # Up from 0 wraps to the last item.
      render_hook(view, "palette:nav", %{"dir" => "up"})
      render_hook(view, "palette:nav", %{"dir" => "up"})
      assert :sys.get_state(view.pid).socket.assigns.palette_selected_idx == total - 1

      # Down from last wraps back to 0.
      render_hook(view, "palette:nav", %{"dir" => "down"})
      assert :sys.get_state(view.pid).socket.assigns.palette_selected_idx == 0
    end

    test "palette offers the raw terminal action and no governed action", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

      # Terminals are raw everywhere now.
      assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :raw

      render_hook(view, "palette:open", %{})

      ids =
        :sys.get_state(view.pid).socket.assigns.palette_items
        |> Enum.map(& &1.id)

      assert "action:terminal:raw" in ids,
             "palette should always offer the raw terminal action"

      refute "action:terminal:governed" in ids,
             "the governed action was removed"
    end

    test "query change resets selection to top", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

      render_hook(view, "palette:open", %{})
      render_hook(view, "palette:nav", %{"dir" => "down"})
      assert :sys.get_state(view.pid).socket.assigns.palette_selected_idx == 1

      render_hook(view, "palette:query", %{"query" => "term"})
      assert :sys.get_state(view.pid).socket.assigns.palette_selected_idx == 0
    end

    test "filter narrows results when query changes (no debounce)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

      render_hook(view, "palette:open", %{})
      total = length(:sys.get_state(view.pid).socket.assigns.palette_items)

      # Typing a specific token should reduce the result set and surface the
      # matching action.
      render_hook(view, "palette:query", %{"query" => "split"})
      filtered = :sys.get_state(view.pid).socket.assigns.palette_items

      assert filtered != [], "filter should still return matches for 'split'"
      assert length(filtered) < total, "filter should narrow the result set"

      assert Enum.any?(filtered, &String.contains?(String.downcase(&1.label), "split")),
             "narrowed results should include the split actions"
    end

    test "form submit (Enter) dispatches the selected item to its event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

      # Terminals are raw everywhere now.
      assert :sys.get_state(view.pid).socket.assigns.terminal_mode == :raw

      render_hook(view, "palette:open", %{})

      # Submit the raw terminal action explicitly via the form submit path
      # (`_selected_id`). It (re)focuses the raw surface and closes the palette.
      render_hook(view, "palette:execute", %{
        "_selected_id" => "action:terminal:raw",
        "query" => ""
      })

      st = :sys.get_state(view.pid).socket.assigns
      assert st.palette_open == false, "executing an item must close the palette"
      assert st.terminal_mode == :raw, "terminal stays raw"
    end

    test "tmux palette hides multi-pane verbs on a single pane", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

      render_hook(view, "palette:ide", %{})

      st = :sys.get_state(view.pid).socket.assigns
      assert st.palette_open == true
      assert st.palette_category == :tmux
      ids = Enum.map(st.palette_items, & &1.id)

      refute "tmux:next_pane" in ids
      refute "tmux:equalize" in ids
      refute Enum.any?(ids, &String.starts_with?(&1, "pane:focus:"))
      refute Enum.any?(ids, &String.starts_with?(&1, "template:"))
      assert "tmux:new_window" in ids
      assert "tmux:split_right" in ids
    end

    test "palette query surfaces apply and preview template rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

      render_hook(view, "palette:open", %{})
      render_hook(view, "palette:category", %{"category" => "tmux"})
      render_hook(view, "palette:query", %{"query" => "agent_pair"})

      ids =
        :sys.get_state(view.pid).socket.assigns.palette_items
        |> Enum.map(& &1.id)

      assert "template:apply:agent_pair" in ids
      assert "template:preview:agent_pair" in ids
    end

    test "form submit with empty _selected_id closes the palette without dispatching",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

      render_hook(view, "palette:open", %{})
      before_mode = :sys.get_state(view.pid).socket.assigns.terminal_mode

      render_hook(view, "palette:execute", %{"_selected_id" => "", "query" => ""})

      st = :sys.get_state(view.pid).socket.assigns
      assert st.palette_open == false
      assert st.terminal_mode == before_mode, "no action should fire on empty submit"
    end
  end

  describe "PTY data side channels" do
    test "{:pty_data, ...} stays side-channel only while PaneWorker owns output buffering",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

      ref = Process.monitor(view.pid)

      payloads = for i <- 1..5, do: "chunk-#{i};"
      for p <- payloads, do: send(view.pid, {:pty_data, "pane-1", p})

      # Drain the LV inbox of the :pty_data messages. Rendering/output
      # coalescing now lives in PaneWorker; LiveView should only run cheap
      # byte-stream side channels (OSC52 clipboard + preview URL detection).
      assigns = :sys.get_state(view.pid).socket.assigns

      refute_receive {:DOWN, ^ref, :process, _, _}, 100
      assert Process.alive?(view.pid)
      Process.demonitor(ref, [:flush])

      refute Map.has_key?(assigns, :pane_pty_buffer)
      refute Map.has_key?(assigns, :pane_refresh_pending)
    end
  end
end
