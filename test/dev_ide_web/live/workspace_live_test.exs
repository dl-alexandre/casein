defmodule DevIdeWeb.WorkspaceLiveTest do
  use DevIdeWeb.ConnCase, async: false

  # Not imported: `Phoenix.ChannelTest.connect/2` collides with ConnTest's
  # HTTP CONNECT verb macro and `push/3` with `Plug.Conn.push/3` (both
  # imported via ConnCase). The few channel calls below are fully qualified.
  require Phoenix.ChannelTest
  import Phoenix.LiveViewTest

  alias DevIDE.Audit
  alias DevIDE.Commands.History
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Runs.Ledger
  alias DevIDE.Terminals.Templates
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    bypass = Bypass.open()
    prev = Application.get_env(:dev_ide, :manager_url)
    alpha_tmux_prefix = DevIDE.Terminals.Tmux.workspace_session_prefix("alpha")

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")

    kill_tmux_sessions_with_prefix(alpha_tmux_prefix)
    MemoryAdapter.clear()
    Audit.clear()
    History.MemoryAdapter.clear()
    DevIDE.Runners.clear()
    DevIDE.Runtimes.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      History.MemoryAdapter.clear()
      DevIDE.Runners.clear()
      DevIDE.Runtimes.clear()
      kill_tmux_sessions_with_prefix(alpha_tmux_prefix)

      if prev,
        do: Application.put_env(:dev_ide, :manager_url, prev),
        else: Application.delete_env(:dev_ide, :manager_url)
    end)

    {:ok, bypass: bypass}
  end

  test "lists workspaces from a fake manager", %{conn: conn, bypass: bypass} do
    Bypass.expect(bypass, "GET", "/api/workspaces", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!([
          %{
            "id" => "abc",
            "name" => "alpha",
            "user" => "alice",
            "status" => "running",
            "type" => "v3",
            "branch" => "main"
          }
        ])
      )
    end)

    {:ok, _view, html} = live(conn, ~p"/workspaces")
    assert html =~ "alpha"
    assert html =~ "running"
  end

  test "workspace picker shows path context and active session count", %{
    conn: conn,
    bypass: bypass
  } do
    prev_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    workspace_id = "ctx-#{System.unique_integer([:positive])}"
    workspace_name = "context-ws-#{System.unique_integer([:positive])}"

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "devide_#{workspace_name}_u-alice" => [
        %{
          id: "@1",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ]
    })

    on_exit(fn ->
      restore(:tmux_adapter, prev_adapter)
      restore(:fake_tmux_windows, prev_windows)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!([
          %{
            "id" => workspace_id,
            "name" => workspace_name,
            "user" => "alice",
            "status" => "running",
            "type" => "v3",
            "branch" => "feature/devide",
            "path" => "/data/workspaces/alice/#{workspace_name}"
          }
        ])
      )
    end)

    {:ok, _view, html} = live(conn, ~p"/workspaces")

    assert html =~ "alice/#{workspace_name}"
    assert html =~ "feature/devide"
    assert html =~ "session=u-alice"
    assert html =~ "workspace"
  end

  test "opens an allowed folder path from the picker", %{conn: conn, bypass: bypass} do
    root = Path.join(System.tmp_dir!(), "devide-open-folder-#{System.unique_integer()}")
    folder = Path.join(root, "oss")
    File.mkdir_p!(folder)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_roots = Application.get_env(:dev_ide, :workspaces_roots)
    Application.put_env(:dev_ide, :workspaces_root, root)
    Application.put_env(:dev_ide, :workspaces_roots, [])

    on_exit(fn ->
      File.rm_rf(root)
      restore(:workspaces_root, prev_root)
      restore(:workspaces_roots, prev_roots)
    end)

    Bypass.stub(bypass, "GET", "/api/workspaces", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!([]))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces")
    folder_id = "folder:" <> Base.url_encode64(folder, padding: false)

    view
    |> form("#attach-folder-form", %{"folder" => %{"path" => folder}})
    |> render_submit()

    assert_redirect(view, ~p"/workspaces/#{folder_id}")
  end

  test "browses allowed folders from the picker", %{conn: conn, bypass: bypass} do
    root = Path.join(System.tmp_dir!(), "devide-browse-folder-#{System.unique_integer()}")
    child = Path.join(root, "child")
    nested = Path.join(child, "nested")
    File.mkdir_p!(nested)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_roots = Application.get_env(:dev_ide, :workspaces_roots)
    Application.put_env(:dev_ide, :workspaces_root, root)
    Application.put_env(:dev_ide, :workspaces_roots, [])

    on_exit(fn ->
      File.rm_rf(root)
      restore(:workspaces_root, prev_root)
      restore(:workspaces_roots, prev_roots)
    end)

    Bypass.stub(bypass, "GET", "/api/workspaces", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!([]))
    end)

    {:ok, view, html} = live(conn, ~p"/workspaces")
    assert html =~ "child"

    html = render_click(view, "folder:browse", %{"path" => child})
    assert html =~ "nested"
    assert html =~ child

    folder_id = "folder:" <> Base.url_encode64(nested, padding: false)
    render_click(view, "folder:open", %{"path" => nested})

    assert_redirect(view, ~p"/workspaces/#{folder_id}")
  end

  test "rejects folder paths outside allowed roots from the picker", %{
    conn: conn,
    bypass: bypass
  } do
    base = Path.join(System.tmp_dir!(), "devide-open-folder-#{System.unique_integer()}")
    root = Path.join(base, "allowed")
    outside = Path.join(base, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_roots = Application.get_env(:dev_ide, :workspaces_roots)
    Application.put_env(:dev_ide, :workspaces_root, root)
    Application.put_env(:dev_ide, :workspaces_roots, [])

    on_exit(fn ->
      File.rm_rf(base)
      restore(:workspaces_root, prev_root)
      restore(:workspaces_roots, prev_roots)
    end)

    Bypass.stub(bypass, "GET", "/api/workspaces", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!([]))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces")

    html =
      view
      |> form("#attach-folder-form", %{"folder" => %{"path" => outside}})
      |> render_submit()

    assert html =~ "Folder path is outside the allowed roots."
  end

  test "admin all-users workspace picker does not poll full list on refresh", %{
    conn: conn,
    bypass: bypass
  } do
    prev_user = Application.get_env(:dev_ide, :current_user)

    Application.put_env(:dev_ide, :current_user, %{
      id: "admin",
      username: "admin",
      email: "admin@local",
      role: :admin
    })

    on_exit(fn -> restore(:current_user, prev_user) end)

    counter = :counters.new(1, [])

    Bypass.stub(bypass, "GET", "/api/workspaces", fn conn ->
      :counters.add(counter, 1, 1)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!([workspace_index_payload("alpha")]))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces")
    assert :counters.get(counter, 1) == 1
    assert has_element?(view, "button[phx-click='toggle_all']", "showing: all users")

    send(view.pid, :refresh)
    :sys.get_state(view.pid)

    assert :counters.get(counter, 1) == 1
  end

  test "non-admin workspace picker still refreshes scoped list", %{conn: conn, bypass: bypass} do
    counter = :counters.new(1, [])

    Bypass.stub(bypass, "GET", "/api/workspaces", fn conn ->
      :counters.add(counter, 1, 1)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!([workspace_index_payload("alpha")]))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces")
    assert :counters.get(counter, 1) == 1

    send(view.pid, :refresh)
    :sys.get_state(view.pid)

    assert :counters.get(counter, 1) == 2
  end

  test "shows actionable error when the workspace source is unreachable", %{
    conn: conn,
    bypass: bypass
  } do
    Bypass.down(bypass)
    {:ok, view, html} = live(conn, ~p"/workspaces")
    assert html =~ "Workspace source is not reachable" or html =~ "Transport error"
  end

  test "renders the picker as a host-grouped list with a derived mode badge", %{
    conn: conn,
    bypass: bypass
  } do
    Bypass.expect(bypass, "GET", "/api/workspaces", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!([
          %{
            "id" => "abc",
            "name" => "alpha",
            "user" => "alice",
            "status" => "running",
            "type" => "v3",
            "branch" => "main"
          }
        ])
      )
    end)

    {:ok, view, html} = live(conn, ~p"/workspaces")

    # product.md §9.1 — picker is the first screen.
    assert html =~ "Connect to a workspace"

    # FP-4 / §11 — mode is derived from capabilities. With no remote/fleet
    # signals registered, the synthetic host is local.
    assert html =~ "local"

    # capability chips appear (synthetic local host advertises these)
    assert html =~ "tmux"
    assert html =~ "audit"

    # workspace still renders under its host so previous behavior is preserved.
    assert html =~ "alpha"
    assert html =~ "running"

    assert has_element?(view, "a[href='/workspaces/abc']", "alpha")
  end

  test "run tab renders canonical run ledger timeline", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-live")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    run_id = Ledger.new_run_id()

    Ledger.command_requested(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id,
      plane: "safe_action",
      metadata: %{source: "ui", protocol: "devide.immediate.v1"}
    })

    Ledger.run_started(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id
    })

    Ledger.run_finished(:succeeded, %{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id,
      metadata: %{exit_code: 0}
    })

    {:ok, history} =
      History.start_run(%{
        id: run_id,
        workspace_id: "ws-1",
        actor_id: "dev",
        command_id: "test",
        started_at: DateTime.utc_now()
      })

    {:ok, _} =
      History.finish_run(history.id, %{
        status: :succeeded,
        exit_code: 0,
        started_at: history.started_at,
        finished_at: DateTime.utc_now(),
        output: "ok\n"
      })

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    html = open_run_panel(view)

    assert has_element?(view, "#run-ledger")
    assert has_element?(view, "#run-ledger-run-#{run_id}")
    assert has_element?(view, "#run-ledger-timeline")
    assert html =~ "run.command_requested"
    assert html =~ "run.started"
    assert html =~ "run.succeeded"
    assert html =~ "command output"
    assert html =~ "ok"
    refute html =~ "Recent runs"
    refute has_element?(view, "button[phx-click='run_history:toggle']")
  end

  test "terminal tab renders tmux windows as actionable tabs", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-tmux-tabs")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_fake_tmux_next_window = TmuxCtl.Test.FakeState.get(:fake_tmux_next_window)

    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "alpha-#{System.unique_integer([:positive])}"
    tmux_session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev")
    extra_tmux_session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev-extra")
    activity_now = DateTime.utc_now() |> DateTime.to_unix()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{
          id: "@0",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: activity_now - 120,
          current_command: "bash"
        },
        %{
          id: "@1",
          index: 1,
          name: "tests",
          active: false,
          panes: 3,
          activity: activity_now,
          current_command: "mix"
        }
      ],
      extra_tmux_session => [
        %{
          id: "@0",
          index: 0,
          name: "scratch",
          active: true,
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
          active: false,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: workspace_path,
          activity: activity_now - 120,
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
          width: 60,
          height: 20,
          current_command: "mix",
          current_path: workspace_path,
          activity: activity_now,
          activity_flag: false,
          bell: false,
          unseen_changes: false
        },
        %{
          id: "%3",
          window_id: "@1",
          index: 1,
          active: false,
          left: 0,
          top: 20,
          width: 60,
          height: 20,
          current_command: "tail",
          current_path: workspace_path,
          activity: activity_now,
          activity_flag: true,
          bell: false,
          unseen_changes: true
        },
        %{
          id: "%2",
          window_id: "@1",
          index: 2,
          active: false,
          left: 60,
          top: 0,
          width: 60,
          height: 40,
          current_command: "iex",
          current_path: Path.join(workspace_path, "apps/web"),
          activity: activity_now - 120,
          activity_flag: false,
          bell: true,
          unseen_changes: false
        }
      ],
      extra_tmux_session => [
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
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_next_window, %{tmux_session => "@2"})

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
      restore(:fake_tmux_next_window, prev_fake_tmux_next_window)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path, workspace_name)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?window=@1")
    await_mount_hydration(view)

    assert_receive {:fake_tmux_select_window, ^tmux_session, "@1"}
    assert has_element?(view, "#session-dropdown-ws-1")
    assert has_element?(view, "#window-dropdown-ws-1")
    assert has_element?(view, "#terminal-session-shell-ws-1")
    refute has_element?(view, "#terminal-session-shell-ws-1", "Shell")
    assert has_element?(view, "[phx-value-session-id='u-dev-extra']")
    refute has_element?(view, "[phx-value-session-id='u-dev-extra']", "Shell")
    assert has_element?(view, "#window-dropdown-ws-1")

    # Choose-tree: the session dropdown shows a window count per session and
    # an expandable window list.
    assert has_element?(view, "button[title='1 window']", "1")
    assert has_element?(view, "#session-windows-active_sessions-u-dev-extra a", "scratch")

    view
    |> element("#active_sessions-u-dev-extra")
    |> render_click()

    assert_patch(view, "/workspaces/ws-1?session=u-dev-extra&window=%400")
    refute_received {:fake_tmux_select_window, ^extra_tmux_session, "@0"}

    assert has_element?(
             view,
             "[phx-value-session-id='u-dev-extra'][class*='text-primary']"
           )

    # Clicking an expanded window row attaches the session and selects that
    # window (choose-tree style).
    view
    |> element("#session-windows-active_sessions-u-dev-extra a[phx-value-window-id='@0']")
    |> render_click()

    assert_receive {:fake_tmux_select_window, ^extra_tmux_session, "@0"}
    assert_patch(view, "/workspaces/ws-1?session=u-dev-extra&window=%400")

    assert has_element?(view, "#tmux-window--0 a", "scratch")
    refute has_element?(view, "#tmux-window--1 a", "tests")

    document = view |> render() |> LazyHTML.from_fragment()
    terminal = LazyHTML.query(document, "#terminal-ws-1-u-dev-extra-governed")
    assert LazyHTML.attribute(terminal, "data-sid") == ["u-dev-extra"]
    assert LazyHTML.attribute(terminal, "data-active-tmux-session") == [extra_tmux_session]
    assert LazyHTML.attribute(terminal, "data-terminal-mode") == ["governed"]
    assert LazyHTML.attribute(terminal, "data-capability-sid") == ["u-dev-extra"]
    [capability] = LazyHTML.attribute(terminal, "data-terminal-capability")
    [socket_token] = LazyHTML.attribute(terminal, "data-socket-token")
    assert {:ok, claims} = DevIdeWeb.ChannelAuth.verify_terminal_capability(capability)
    assert claims[:terminal_sid] == "u-dev-extra"

    assert {:ok, browser_socket} =
             Phoenix.ChannelTest.connect(DevIdeWeb.UserSocket, %{"token" => socket_token})

    assert {:ok, channel_reply, channel_socket} =
             Phoenix.ChannelTest.subscribe_and_join(
               browser_socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:u-dev-extra",
               %{
                 "mode" => "governed",
                 "host_id" => "local",
                 "terminal_capability" => capability
               }
             )

    assert channel_reply.mode == "governed"
    ref = Phoenix.ChannelTest.push(channel_socket, "command", %{"line" => "   "})
    Phoenix.ChannelTest.assert_reply(ref, :ok, %{status: "blank"})
    :ok = DevIDE.Terminals.owner_detach(channel_socket.assigns.terminal_owner_pid, self())

    view
    |> element("#terminal-session-shell-ws-1")
    |> render_click()

    assert_patch(view, "/workspaces/ws-1?window=%401")
    refute_received {:fake_tmux_select_window, ^tmux_session, "@1"}

    assert has_element?(view, "#tmux-window--1 a[phx-value-window-id='@1']")
    assert has_element?(view, "#tmux-window-activity--1[data-activity-state='fresh']")
    assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%1']")

    assert has_element?(
             view,
             "#tmux-pane-layout-ws-1[phx-hook='TmuxPaneResize'][data-resize-max='50']"
           )

    assert has_element?(view, "#tmux-pane--1[data-pane-active='true']")
    assert has_element?(view, "#tmux-pane--2[data-pane-active='false']")
    assert has_element?(view, "#tmux-pane-status--1[data-pane-status='active']")

    assert has_element?(
             view,
             "#tmux-pane-status--2[data-pane-status='bell'][data-pane-bell='true']"
           )

    assert has_element?(view, "#tmux-pane-status--3[data-pane-status='fresh']")
    refute has_element?(view, "#tmux-pane-drag-right--1")

    assert has_element?(
             view,
             "#tmux-pane-drag-right--2[data-tmux-resize-handle='true'][data-resize-axis='x'][data-pane-id='%2']"
           )

    assert has_element?(
             view,
             "#tmux-pane-drag-down--2[data-tmux-resize-handle='true'][data-resize-axis='y'][data-pane-id='%2']"
           )

    pane_html = view |> element("#tmux-pane--2") |> render()
    assert pane_html =~ "left: 50.0%;"
    assert pane_html =~ "width: 50.0%;"
    assert has_element?(view, "#tmux-pane-title--2", "web · iex")
    assert has_element?(view, "#tmux-pane--2[title$='apps/web · iex']")

    view
    |> element("#tmux-pane--2")
    |> render_click()

    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%2"}
    assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%2']")

    assert_push_event(view, "terminal:focus_active", %{
      "reason" => "tmux:select_pane",
      "tmux_pane_id" => "%1"
    })

    assert has_element?(view, "#tmux-pane--1[data-pane-active='false']")
    assert has_element?(view, "#tmux-pane--2[data-pane-active='true']")
    assert has_element?(view, "#tmux-window--1 a[title*='apps/web · iex']")

    view
    |> element("#tmux-pane-kill--1")
    |> render_click()

    assert_receive {:fake_tmux_kill_pane, ^tmux_session, "%1"}
    assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%2']")

    assert_push_event(view, "terminal:focus_active", %{
      "reason" => "tmux:kill_pane",
      "tmux_pane_id" => "%2"
    })

    refute has_element?(view, "#tmux-pane--1")
    assert has_element?(view, "#tmux-pane--2[data-pane-active='true']")
    assert has_element?(view, "#tmux-pane--3[data-pane-active='false']")

    view
    |> element("#tmux-pane-split-v--3")
    |> render_click()

    assert_receive {:fake_tmux_split_pane, ^tmux_session, "%3", "v", "%4"}
    assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%4']")

    assert_push_event(view, "terminal:focus_active", %{
      "reason" => "tmux:split_pane",
      "tmux_pane_id" => "%2"
    })

    assert has_element?(view, "#tmux-pane--2[data-pane-active='false']")
    assert has_element?(view, "#tmux-pane--3[data-pane-active='false']")
    assert has_element?(view, "#tmux-pane--4[data-pane-active='true']")

    split_html = view |> element("#tmux-pane--4") |> render()
    assert split_html =~ "top: 75.0%;"
    assert split_html =~ "height: 25.0%;"

    view
    |> element("#tmux-pane-resize-down--3")
    |> render_click()

    assert_receive {:fake_tmux_resize_pane, ^tmux_session, "%3", "down", 5}
    assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%4']")
    assert has_element?(view, "#tmux-pane--3[data-pane-active='false']")
    assert has_element?(view, "#tmux-pane--4[data-pane-active='true']")

    resized_pane_html = view |> element("#tmux-pane--3") |> render()
    assert resized_pane_html =~ "height: 37.5%;"

    resized_neighbor_html = view |> element("#tmux-pane--4") |> render()
    assert resized_neighbor_html =~ "top: 87.5%;"
    assert resized_neighbor_html =~ "height: 12.5%;"

    render_click(view, "tmux:resize_pane", %{"pane-id" => "%3", "direction" => "down"})

    assert_receive {:fake_tmux_resize_pane, ^tmux_session, "%3", "down", 5}
    assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%4']")

    render_click(view, "tmux:resize_pane", %{
      "pane-id" => "%3",
      "direction" => "down",
      "amount" => "51"
    })

    refute_receive {:fake_tmux_resize_pane, ^tmux_session, "%3", "down", 51}

    # Hidden leader-key targets render for C-b dispatch (see the dedicated
    # "leader-key dispatch targets" test for the full contract).
    assert has_element?(view, "button[data-leader-action='detach']")
    assert has_element?(view, "button[data-leader-action='palette']")
    assert has_element?(view, "button[data-leader-action='help']")
    assert has_element?(view, "button[data-leader-action='last-window']")
    assert has_element?(view, "button[data-leader-action='last-pane']")
    assert has_element?(view, "button[data-leader-action='kill-window'][phx-value-window-id]")
    assert has_element?(view, "button[data-leader-action='rename-window'][phx-value-window-id]")

    for action <- ~w(pane-left pane-down pane-up pane-right pane-next) do
      assert has_element?(
               view,
               "button[data-leader-action='#{action}'][phx-click='pane:navigate']"
             )
    end

    assert has_element?(view, "#leader-cheatsheet")
    assert has_element?(view, ".leader-key-control[data-shortcut='Ctrl + B, then N']")

    assert has_element?(
             view,
             ".leader-key-control[data-shortcut='Ctrl + B, then N'] button[title='Next window. Shortcut: Ctrl + B, then N']"
           )

    assert has_element?(view, ".leader-key-control[data-shortcut='Ctrl + B, then S']")
    assert has_element?(view, ".leader-key-control[data-shortcut='Ctrl + B, then W']")
    assert has_element?(view, "button[data-shortcut='Ctrl/Cmd + Shift + F']")

    cheatsheet_html = render(view)
    assert cheatsheet_html =~ "Ctrl+P"
    assert cheatsheet_html =~ "show pane numbers"
    assert cheatsheet_html =~ "Inside the command palette"

    # C-b l: switching @1 -> @0 records @1 as last; last_window toggles back.
    render_click(view, "tmux:select_window", %{"window-id" => "@0"})
    assert_receive {:fake_tmux_select_window, ^tmux_session, "@0"}
    assert_patch(view, "/workspaces/ws-1?window=%400")

    render_click(view, "tmux:last_window", %{})
    assert_receive {:fake_tmux_select_window, ^tmux_session, "@1"}
    assert_patch(view, "/workspaces/ws-1?window=%401")

    # C-b ; delegates to tmux select-pane -l on the active session.
    render_click(view, "pane:navigate", %{"dir" => "last"})
    assert_receive {:fake_tmux_navigate_pane, ^tmux_session, "l"}

    # C-b ←/→/↑/↓ leader dispatch targets (hidden buttons; JS pushes pane:navigate).
    render_click(view, "pane:navigate", %{"dir" => "left"})
    assert_receive {:fake_tmux_navigate_pane, ^tmux_session, "L"}
    assert_push_event(view, "terminal:focus_active", %{"reason" => "pane:navigate"})

    view
    |> element("#tmux-window--1 button[phx-click='tmux:rename_start']")
    |> render_click()

    assert has_element?(view, "#tmux-rename-form--1")

    view
    |> form("#tmux-rename-form--1", %{"window" => %{"id" => "@1", "name" => "ci"}})
    |> render_submit()

    assert_receive {:fake_tmux_rename_window, ^tmux_session, "@1", "ci"}
    assert has_element?(view, "#window-dropdown-ws-1", "ci")

    view
    |> element("button[aria-label='New tmux window']")
    |> render_click()

    assert_receive {:fake_tmux_ensure_session, ^tmux_session, ^workspace_path}
    assert_receive {:fake_tmux_new_window, ^tmux_session, _opts}
    assert_patch(view, "/workspaces/ws-1?window=%402")
    assert_push_event(view, "terminal:focus_active", %{"reason" => "tmux:new_window"})

    view
    |> element("#tmux-window--0 button[title='Close tmux window']")
    |> render_click()

    assert_receive {:fake_tmux_kill_window, ^tmux_session, "@0"}
    assert_push_event(view, "terminal:focus_active", %{"reason" => "tmux:kill_window"})
    refute has_element?(view, "#tmux-window--0")
  end

  test "leader-key dispatch targets are unique and survive focus mode", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-leader-targets")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "leader-#{System.unique_integer([:positive])}"
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
        }
      ]
    })

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path, workspace_name)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1")
    await_mount_hydration(view)

    # Every dispatch-only WorkspaceLeader action has a hidden target.
    for action <- ~w(detach palette help last-window last-pane next-window prev-window) do
      assert has_element?(view, "button[data-leader-action='#{action}']")
    end

    for action <- ~w(pane-left pane-down pane-up pane-right pane-next) do
      assert has_element?(
               view,
               "button[data-leader-action='#{action}'][phx-click='pane:navigate']"
             )
    end

    assert has_element?(view, "button[data-leader-action='kill-window'][phx-value-window-id]")
    assert has_element?(view, "button[data-leader-action='rename-window'][phx-value-window-id]")

    # Exactly one element per action — WorkspaceLeader clicks the first match,
    # so a duplicate would shadow the real handler (docs/leader_keys.md).
    leader_actions =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.filter("[data-leader-action]")
      |> LazyHTML.attribute("data-leader-action")

    assert leader_actions == Enum.uniq(leader_actions)

    # Targets survive focus mode (chrome hidden): the dispatch div renders
    # outside the chrome block, so C-b bindings keep working when leader keys
    # are the only affordance left.
    render_click(view, "terminal:toggle_chrome", %{})
    refute has_element?(view, "#window-dropdown-ws-1")

    for action <- ~w(detach palette help last-window last-pane next-window prev-window) do
      assert has_element?(view, "button[data-leader-action='#{action}']")
    end

    for action <- ~w(pane-left pane-down pane-up pane-right pane-next) do
      assert has_element?(view, "button[data-leader-action='#{action}']")
    end

    assert has_element?(view, "button[data-leader-action='kill-window']")
    assert has_element?(view, "button[data-leader-action='rename-window']")
  end

  test "session bar folds owned workspace sessions and hides teammate sessions", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-owned-session-bar")
    workspace_path = Path.join(workspace_root, "current")
    owned_path = Path.join(workspace_root, "owned")
    teammate_path = Path.join(workspace_root, "teammate")
    File.mkdir_p!(workspace_path)
    File.mkdir_p!(owned_path)
    File.mkdir_p!(teammate_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_user = Application.get_env(:dev_ide, :current_user)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)

    Application.put_env(:dev_ide, :current_user, %{
      id: "alice",
      username: "alice",
      email: "alice@example.com",
      role: :owner
    })

    current_tmux = DevIDE.Terminals.Tmux.session_name("alpha", "u-alice")
    owned_tmux = DevIDE.Terminals.Tmux.session_name("alice-owned", "u-alice-owned")
    teammate_tmux = DevIDE.Terminals.Tmux.session_name("bob-owned", "u-bob-owned")
    activity_now = DateTime.utc_now() |> DateTime.to_unix()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      current_tmux => [tmux_window(activity_now)],
      owned_tmux => [tmux_window(activity_now)],
      teammate_tmux => [tmux_window(activity_now)]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      current_tmux => [tmux_pane(workspace_path)],
      owned_tmux => [tmux_pane(owned_path)],
      teammate_tmux => [tmux_pane(teammate_path)]
    })

    _ =
      DevIDE.Workspaces.State.sync(%DevIDE.Workspace{
        id: "owned-ws",
        name: "alice-owned",
        user: "alice",
        status: :running,
        path: owned_path,
        metadata: %{raw: %{"user" => "alice"}}
      })

    _ =
      DevIDE.Workspaces.State.sync(%DevIDE.Workspace{
        id: "teammate-ws",
        name: "bob-owned",
        user: "bob",
        status: :running,
        path: teammate_path,
        metadata: %{raw: %{"user" => "bob"}}
      })

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:current_user, prev_user)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    refute has_element?(view, "#workspace-session-rail")

    assert has_element?(view, "#workspace_sessions-owned-ws-u-alice-owned")

    refute has_element?(view, "#workspace_sessions-owned-ws-u-alice-owned", "Shell")

    assert has_element?(view, "a[href*='/workspaces/owned-ws'][href*='session=u-alice-owned']")
    refute has_element?(view, "a[href*='/workspaces/teammate-ws']")
  end

  test "session tabs keep sibling browser tab shells and explicit shells", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-stale-browser-tabs")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "alpha"
    current_sid = "u-dev-abcd1234"
    stale_sid = "u-dev-deadbeef"
    explicit_sid = "u-dev-extra"
    current_tmux_session = DevIDE.Terminals.Tmux.session_name(workspace_name, current_sid)
    stale_tmux_session = DevIDE.Terminals.Tmux.session_name(workspace_name, stale_sid)
    explicit_tmux_session = DevIDE.Terminals.Tmux.session_name(workspace_name, explicit_sid)
    activity_now = DateTime.utc_now() |> DateTime.to_unix()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      current_tmux_session => [
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
      stale_tmux_session => [
        %{
          id: "@0",
          index: 0,
          name: "old-tab",
          active: true,
          panes: 1,
          activity: activity_now,
          current_command: "bash"
        }
      ],
      explicit_tmux_session => [
        %{
          id: "@0",
          index: 0,
          name: "scratch",
          active: true,
          panes: 1,
          activity: activity_now,
          current_command: "bash"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      current_tmux_session => [
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
        }
      ],
      explicit_tmux_session => [
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
        }
      ]
    })

    {:ok, _} = Registry.register(DevIDE.Terminals.Registry, {"ws-1", stale_sid}, nil)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path, workspace_name)
    end)

    conn = put_connect_params(conn, %{"tab_id" => "abcd1234"})
    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    assert has_element?(view, "#terminal-session-shell-ws-1")
    refute has_element?(view, "#terminal-session-shell-ws-1", "Shell")
    assert has_element?(view, "[phx-value-session-id='#{stale_sid}']")
    assert has_element?(view, "[phx-value-session-id='#{explicit_sid}']")

    # A session appearing elsewhere reaches this viewer via the directory
    # broadcast — no click on the refresh button involved.
    second_sid = "u-dev-second"
    second_tmux_session = DevIDE.Terminals.Tmux.session_name(workspace_name, second_sid)

    TmuxCtl.Test.FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, second_tmux_session, [
        %{
          id: "@0",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: activity_now,
          current_command: "bash"
        }
      ])
    end)

    _ = DevIDE.Terminals.SessionDirectory.refresh_now("ws-1", workspace_name: workspace_name)

    assert has_element?(view, "[phx-value-session-id='#{second_sid}']")
    assert has_element?(view, "[phx-value-session-id='#{stale_sid}']")
  end

  test "stale terminal session tab shows friendly error without switching", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-stale-session")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "stale-#{System.unique_integer([:positive])}"
    tmux_session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev")

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{
          id: "@0",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: 0,
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
          activity: 0,
          activity_flag: false,
          bell: false,
          unseen_changes: false
        }
      ]
    })

    {:ok, _} = Registry.register(DevIDE.Terminals.Registry, {"ws-1", "u-dev-stale"}, nil)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path, workspace_name)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    assert has_element?(view, "[phx-value-session-id='u-dev-stale']")

    view
    |> element("[phx-value-session-id='u-dev-stale']")
    |> render_click()

    assert has_element?(view, "#flash-error", "Terminal session ended. Refreshed sessions.")
    assert has_element?(view, "#terminal-session-shell-ws-1[class*='text-primary']")

    document = view |> render() |> LazyHTML.from_fragment()
    terminal = LazyHTML.query(document, "#terminal-ws-1-u-dev-governed")
    assert LazyHTML.attribute(terminal, "data-sid") == ["u-dev"]
    assert LazyHTML.attribute(terminal, "data-active-tmux-session") == [tmux_session]
  end

  test "stopped workspace does not block host-backed raw terminal", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-stopped-workspace-terminal")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)

    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    {:ok, _} = DevIDE.Workspaces.State.set_mode("ws-1", :manual)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path, "alpha", "stopped")
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    assert has_element?(view, "#workspace-start-button", "Start")
    refute has_element?(view, "#terminal-workspace-start-button")
    refute has_element?(view, "#terminal-workspace-start-unavailable")
    refute has_element?(view, "[role='alert']", "Terminal failed to start")
  end

  test "workspace start failure shows manager message without raw http tuple", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-bespoke-workspace-start")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)

    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    {:ok, _} = DevIDE.Workspaces.State.set_mode("ws-1", :manual)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path, "alpha", "stopped")
    end)

    Bypass.expect(bypass, "POST", "/api/workspaces/ws-1/start", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        500,
        Jason.encode!(%{
          "error" =>
            "Bespoke workspaces do not use the MILC Docker start flow. Open OpenCode or use the deploy command shown on the card."
        })
      )
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    view
    |> element("#workspace-start-button")
    |> render_click()

    assert has_element?(view, "#flash-error", "Bespoke workspaces do not use")
    refute has_element?(view, "#flash-error", "{:http")
  end

  test "terminal image paste event saves the image under the workspace clipboard", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-image-paste")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    {:ok, _} = DevIDE.Workspaces.State.set_mode("ws-1", :manual)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    render_hook(view, "terminal:paste_image", %{
      "name" => "dropped image.png",
      "type" => "image/png",
      "data" => Base.encode64("png bytes")
    })

    [path] =
      Path.wildcard(
        Path.join([
          workspace_path,
          ".devide",
          "clipboard",
          "*-dropped-image.png"
        ])
      )

    assert File.read!(path) == "png bytes"
  end

  test "split OSC52 terminal output pushes clipboard write event", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-osc52-copy")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    on_exit(fn -> File.rm_rf(workspace_root) end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    text = "copied from claude"
    b64 = Base.encode64(text)

    send(view.pid, {:pty_data, "pane-1", "\x1b]"})
    send(view.pid, {:pty_data, "pane-1", "52;c;" <> binary_part(b64, 0, 5)})
    send(view.pid, {:pty_data, "pane-1", binary_part(b64, 5, byte_size(b64) - 5) <> "\x07"})

    assert_push_event(view, "clipboard:write", %{"text" => ^text})
  end

  test "switching to a fleet execution retargets tmux window tabs to that session", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-session-switch")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    shell_tmux_session = "devide_alpha_u-dev"
    execution_id = "exec-switch-#{System.unique_integer([:positive])}"
    exec_tmux_session = "devide_#{execution_id}"
    activity_now = DateTime.utc_now() |> DateTime.to_unix()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      shell_tmux_session => [
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
      exec_tmux_session => [
        %{
          id: "@0",
          index: 0,
          name: "runner",
          active: true,
          panes: 1,
          activity: activity_now,
          current_command: "mix"
        },
        %{
          id: "@1",
          index: 1,
          name: "logs",
          active: false,
          panes: 1,
          activity: activity_now,
          current_command: "tail"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      shell_tmux_session => [
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
        }
      ],
      exec_tmux_session => [
        %{
          id: "%0",
          window_id: "@0",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "mix",
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
          current_command: "tail",
          current_path: workspace_path,
          activity: activity_now,
          activity_flag: false,
          bell: false,
          unseen_changes: false
        }
      ]
    })

    :ok =
      ExecutionProjectionStore.create(%ExecutionProjection{
        id: execution_id,
        assignment_id: "asg-switch",
        runner_id: "runner-switch",
        lease_id: "lease-switch",
        workspace_id: "ws-1",
        tmux_session: exec_tmux_session,
        state: :started,
        started_at: DateTime.utc_now()
      })

    on_exit(fn ->
      ExecutionProjectionStore.clear()
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)
    exec_session_id = "exec_#{execution_id}"

    assert has_element?(view, "#session-dropdown-ws-1")
    assert has_element?(view, "#window-dropdown-ws-1")
    assert has_element?(view, "#terminal-session-shell-ws-1")
    refute has_element?(view, "#terminal-session-shell-ws-1", "Shell")

    assert has_element?(
             view,
             "#active_sessions-#{exec_session_id}[phx-value-kind='execution']"
           )

    assert has_element?(view, "#tmux-window--0 a", "shell")
    refute has_element?(view, "#tmux-window--1 a", "logs")
    assert has_element?(view, "#tmux-template-palette-ws-1")
    refute has_element?(view, "#active_sessions-#{exec_session_id}[class*='text-primary']")

    view
    |> element("#active_sessions-#{exec_session_id}")
    |> render_click()

    assert has_element?(view, "#active_sessions-#{exec_session_id}[class*='text-primary']")
    assert has_element?(view, "#session-dropdown-ws-1")
    assert has_element?(view, "#window-dropdown-ws-1")
    assert has_element?(view, "#tmux-window--0 a", "runner")
    assert has_element?(view, "#tmux-window--1 a", "logs")
    refute has_element?(view, "#tmux-window--0 a", "shell")
    refute has_element?(view, "#tmux-template-palette-ws-1")
    assert render(view) =~ "fleet exec"

    view
    |> element("#tmux-window--1 a[phx-value-window-id='@1']")
    |> render_click()

    assert_receive {:fake_tmux_select_window, ^exec_tmux_session, "@1"}

    view
    |> element("#terminal-session-shell-ws-1")
    |> render_click()

    assert has_element?(view, "#session-dropdown-ws-1")
    assert has_element?(view, "#window-dropdown-ws-1")
    assert has_element?(view, "#tmux-window--0 a", "shell")
    refute has_element?(view, "#tmux-window--1 a", "logs")
    assert has_element?(view, "#tmux-template-palette-ws-1")
    refute render(view) =~ "fleet exec"
    refute has_element?(view, "#active_sessions-#{exec_session_id}[class*='text-primary']")

    # Regression: a URL-patch-driven switch changes terminal_sid without any
    # event that rebuilds the tab list. Active styling must still follow
    # (the old stream-based tabs only re-styled on a full stream reset).
    render_patch(
      view,
      ~p"/workspaces/ws-1?session=#{exec_session_id}&tmux_session=#{exec_tmux_session}"
    )

    assert has_element?(view, "#active_sessions-#{exec_session_id}[class*='text-primary']")
    refute has_element?(view, "#tmux-template-palette-ws-1")
  end

  test "terminal palette previews and applies a built-in tmux session template", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-template-palette")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_fake_tmux_next_window = TmuxCtl.Test.FakeState.get(:fake_tmux_next_window)

    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "alpha-#{System.unique_integer([:positive])}"
    tmux_session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev")

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{
          id: "@1",
          index: 0,
          name: "main",
          active: true,
          panes: 1,
          activity: DateTime.utc_now() |> DateTime.to_unix(),
          current_command: "bash"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
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
          current_path: workspace_path
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_next_window, %{tmux_session => "@2"})

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
      restore(:fake_tmux_next_window, prev_fake_tmux_next_window)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path, workspace_name)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    assert has_element?(view, "#tmux-template-palette-ws-1")

    view
    |> element("#tmux-template-palette-ws-1")
    |> render_click()

    assert has_element?(
             view,
             "li[phx-value-id='template:preview:generic_project']",
             "Preview template: Generic Project"
           )

    assert has_element?(
             view,
             "li[phx-value-id='template:apply:generic_project']",
             "Apply template: Generic Project"
           )

    view
    |> element("li[phx-value-id='template:preview:generic_project']")
    |> render_click()

    assert has_element?(view, "#template-preview-modal")
    assert has_element?(view, "#template-preview-title", "Generic Project")
    assert has_element?(view, "#template-preview-step-1[data-action='new_window']", "shell")
    assert has_element?(view, "#template-preview-step-2[data-action='split_pane']", "git")
    assert has_element?(view, "#template-preview-step-3[data-action='send_command']")
    assert has_element?(view, "#template-preview-step-3", "git status --short")
    assert has_element?(view, "#template-preview-step-5[data-action='select_pane']")
    refute has_element?(view, "#template-reconcile-summary")
    refute has_element?(view, "#template-preview-apply-exact")
    refute_received {:fake_tmux_new_window, ^tmux_session, _}

    view
    |> element("#template-preview-apply")
    |> render_click()

    assert_receive {:fake_tmux_ensure_session, ^tmux_session, ^workspace_path}
    assert_receive {:fake_tmux_new_window, ^tmux_session, new_window_opts}
    assert new_window_opts[:name] == "shell"
    assert new_window_opts[:cwd] == workspace_path

    assert_receive {:fake_tmux_split_pane, ^tmux_session, "%2", "v", "%3"}
    assert_receive {:fake_tmux_send_command, ^tmux_session, "%3", "git status --short", _}
    assert_receive {:fake_tmux_split_pane, ^tmux_session, "%2", "h", "%4"}
    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%2"}

    assert_patch(view, "/workspaces/ws-1?window=%402")
    refute has_element?(view, "#template-preview-modal")
    assert has_element?(view, "#tmux-window--2")
    assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%2']")
    assert has_element?(view, "#tmux-pane--3", "git status --short")

    assert [%{action: "tmux.template_applied", target_ref: "generic_project"} = event] =
             Audit.recent_for("ws-1", 1)

    assert event.target_type == "tmux_template"
    assert event.actor_id == "dev"
    assert event.metadata.session == tmux_session
    assert event.metadata.step_count == 5
    assert event.metadata.refs["pane:shell:root"] == "%2"
  end

  test "template library saves previews applies and deletes exported layouts", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-template-library")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_fake_tmux_next_window = TmuxCtl.Test.FakeState.get(:fake_tmux_next_window)

    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "alpha-#{System.unique_integer([:positive])}"
    tmux_session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev")

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{
          id: "@1",
          index: 0,
          name: "server",
          active: true,
          panes: 1,
          activity: DateTime.utc_now() |> DateTime.to_unix(),
          current_command: "mix"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "mix",
          current_path: workspace_path
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_next_window, %{tmux_session => "@2"})

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
      restore(:fake_tmux_next_window, prev_fake_tmux_next_window)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path, workspace_name)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    assert has_element?(view, "#tmux-template-library-ws-1")

    view
    |> element("#tmux-template-library-ws-1")
    |> render_click()

    assert has_element?(view, "#template-library-modal")
    assert has_element?(view, "#template-library-empty", "No saved templates")

    view
    |> form("#template-save-form", %{
      "template" => %{
        "name" => "daily_layout",
        "description" => "Daily dev stack",
        "tags" => "daily, phoenix"
      }
    })
    |> render_submit()

    assert [%{id: saved_id, name: "daily_layout"} = saved] =
             Templates.list_for_workspace("ws-1")

    assert saved.description == "Daily dev stack"
    assert saved.tags == ["daily", "phoenix"]
    assert saved.source_session == tmux_session
    assert has_element?(view, "#saved-template-row-#{saved_id}", "daily_layout")
    assert has_element?(view, "#saved-template-tags-#{saved_id}")
    assert has_element?(view, "#saved-template-tag-#{saved_id}-daily", "daily")
    assert has_element?(view, "#saved-template-filter-daily", "daily")

    view
    |> element("#saved-template-edit-#{saved_id}")
    |> render_click()

    assert has_element?(view, "#saved-template-edit-form-#{saved_id}")

    view
    |> form("#saved-template-edit-form-#{saved_id}", %{
      "template" => %{
        "id" => saved_id,
        "name" => "daily_layout_v2",
        "description" => "Updated daily stack",
        "tags" => "phoenix, ci"
      }
    })
    |> render_submit()

    assert [%{id: ^saved_id, name: "daily_layout_v2"} = updated] =
             Templates.list_for_workspace("ws-1")

    assert updated.description == "Updated daily stack"
    assert updated.tags == ["phoenix", "ci"]
    refute has_element?(view, "#saved-template-edit-form-#{saved_id}")
    assert has_element?(view, "#saved-template-row-#{saved_id}", "daily_layout_v2")
    assert has_element?(view, "#saved-template-row-#{saved_id}", "Updated daily stack")
    assert has_element?(view, "#saved-template-tag-#{saved_id}-ci", "ci")

    view
    |> element("#saved-template-duplicate-#{saved_id}")
    |> render_click()

    assert has_element?(view, "#saved-template-duplicate-form-#{saved_id}")

    view
    |> form("#saved-template-duplicate-form-#{saved_id}", %{
      "template" => %{
        "source_id" => saved_id,
        "name" => "daily_layout_clone",
        "description" => "Cloned daily stack",
        "tags" => "clone"
      }
    })
    |> render_submit()

    saved_templates = Templates.list_for_workspace("ws-1")
    assert [%{id: clone_id, name: "daily_layout_clone"}, %{id: ^saved_id}] = saved_templates
    assert [%{tags: ["clone"]}, %{tags: ["phoenix", "ci"]}] = saved_templates
    assert has_element?(view, "#saved-template-row-#{clone_id}", "daily_layout_clone")
    assert has_element?(view, "#saved-template-row-#{clone_id}", "Cloned daily stack")
    assert has_element?(view, "#saved-template-tag-#{clone_id}-clone", "clone")
    assert has_element?(view, "#saved-template-row-#{saved_id}", "daily_layout_v2")

    view
    |> element("#saved-template-filter-clone")
    |> render_click()

    assert has_element?(view, "#saved-template-row-#{clone_id}", "daily_layout_clone")
    refute has_element?(view, "#saved-template-row-#{saved_id}")

    view
    |> element("#saved-template-filter-all")
    |> render_click()

    assert has_element?(view, "#saved-template-row-#{clone_id}", "daily_layout_clone")
    assert has_element?(view, "#saved-template-row-#{saved_id}", "daily_layout_v2")

    view
    |> element("#saved-template-delete-#{clone_id}")
    |> render_click()

    refute has_element?(view, "#saved-template-row-#{clone_id}")
    assert has_element?(view, "#saved-template-row-#{saved_id}", "daily_layout_v2")

    view
    |> element("#saved-template-preview-#{saved_id}")
    |> render_click()

    assert has_element?(view, "#template-preview-modal")
    assert has_element?(view, "#template-preview-title", "daily_layout_v2")
    assert has_element?(view, "#template-reconcile-summary")
    assert has_element?(view, "#template-reconcile-summary-reuse-windows", "1")
    assert has_element?(view, "#template-reconcile-summary-reuse-panes", "1")
    assert has_element?(view, "#template-reconcile-summary-new-panes", "0")

    assert has_element?(
             view,
             "#template-reconcile-change-1[data-action='reuse_window']",
             "server"
           )

    assert has_element?(view, "#template-reconcile-change-2[data-action='reuse_pane']")
    assert has_element?(view, "#template-reconcile-change-3[data-action='select_pane']")
    assert has_element?(view, "#template-exact-plan-note")
    assert has_element?(view, "#template-preview-apply-exact", "Exact replay")

    assert has_element?(
             view,
             "#template-preview-apply[phx-value-mode='reconcile']",
             "Apply reconcile"
           )

    view
    |> element("#template-preview-apply")
    |> render_click()

    assert_receive {:fake_tmux_ensure_session, ^tmux_session, ^workspace_path}
    refute_received {:fake_tmux_new_window, ^tmux_session, _opts}
    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%1"}

    assert has_element?(view, "#tmux-window--1")

    view
    |> element("#tmux-template-library-ws-1")
    |> render_click()

    assert has_element?(view, "#saved-template-row-#{saved_id}")

    view
    |> element("#saved-template-delete-#{saved_id}")
    |> render_click()

    assert Templates.list_for_workspace("ws-1") == []
    refute has_element?(view, "#saved-template-row-#{saved_id}")
    assert has_element?(view, "#template-library-empty", "No saved templates")

    template_events =
      "ws-1"
      |> Audit.recent_for(12)
      |> Enum.filter(&String.starts_with?(&1.action, "tmux.template_"))
      |> Enum.take(6)

    assert [
             %{action: "tmux.template_deleted", target_ref: ^saved_id},
             %{action: "tmux.template_applied", target_ref: ^saved_id} = applied,
             %{action: "tmux.template_deleted", target_ref: ^clone_id},
             %{action: "tmux.template_duplicated", target_ref: ^clone_id} = duplicated,
             %{action: "tmux.template_updated", target_ref: ^saved_id} = updated_event,
             %{action: "tmux.template_saved", target_ref: ^saved_id}
           ] = template_events

    assert applied.metadata.strategy == "reconcile"
    assert applied.metadata.reconciliation.reuse_windows == 1
    assert applied.metadata.reconciliation.new_panes == 0
    assert duplicated.metadata.source_template_id == saved_id
    assert duplicated.metadata.template_name == "daily_layout_clone"
    assert updated_event.metadata.template_name == "daily_layout_v2"
    assert updated_event.metadata.changes.name.before == "daily_layout"
    assert updated_event.metadata.changes.description.after == "Updated daily stack"
    assert updated_event.metadata.changes.tags.before == ["daily", "phoenix"]
    assert updated_event.metadata.changes.tags.after == ["phoenix", "ci"]
  end

  test "evidence drawer can open a ledger run timeline", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-live-evidence")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    run_id = Ledger.new_run_id()

    requested =
      Ledger.command_requested(%{
        workspace_id: "ws-1",
        actor_id: "dev",
        command_id: "format",
        run_id: run_id,
        plane: "safe_action",
        metadata: %{source: "ui", protocol: "devide.immediate.v1"}
      })

    Ledger.run_started(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "format",
      run_id: run_id
    })

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    _html = render_click(view, "audit_drawer:toggle", %{})

    button_id = "#audit-open-run-#{run_id}-#{requested.id}"
    assert has_element?(view, button_id)

    html =
      view
      |> element(button_id)
      |> render_click()

    assert html =~ "Run ledger"
    assert html =~ "run.command_requested"
    assert html =~ "run.started"
    assert has_element?(view, "#run-ledger-run-#{run_id}")
    refute has_element?(view, "aside[aria-label='Evidence drawer']")
  end

  test "run tab shows capped local command output artifact", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-output")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    run_id = Ledger.new_run_id()

    Ledger.command_requested(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id,
      plane: "safe_action",
      metadata: %{source: "ui", protocol: "devide.immediate.v1"}
    })

    Ledger.run_started(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id
    })

    Ledger.run_finished(:succeeded, %{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id,
      metadata: %{exit_code: 0}
    })

    {:ok, history} =
      History.start_run(%{
        id: run_id,
        workspace_id: "ws-1",
        actor_id: "dev",
        command_id: "test",
        started_at: DateTime.utc_now()
      })

    {:ok, _} =
      History.finish_run(history.id, %{
        status: :succeeded,
        exit_code: 0,
        started_at: history.started_at,
        finished_at: DateTime.utc_now(),
        output: "line one\nline two\n"
      })

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    html = open_run_panel(view)

    assert has_element?(view, "#run-artifact-command-output")
    assert html =~ "command output"
    assert html =~ "line one"
    refute html =~ "truncated"
    refute html =~ "runner assignment"
    refute html =~ "Recent runs"
    refute has_element?(view, "button[phx-click='run_history:toggle']")
  end

  test "run tab shows runner-backed assignment artifact", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-runner")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    # Ensure workspace is synced into State so runner enqueue can resolve it.
    {:ok, _ws} = DevIDE.Workspaces.get("ws-1")

    {:ok, assignment} = DevIDE.Runners.enqueue_command("ws-1", "test")
    run_id = assignment.metadata[:run_id]

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    html = open_run_panel(view)

    assert has_element?(view, "#run-ledger")
    assert has_element?(view, "#run-ledger-run-#{run_id}")
    assert has_element?(view, "#run-artifact-runner-assignment")
    assert html =~ "runner assignment"
    assert html =~ assignment.id
    assert html =~ "0"
    assert html =~ "none"
    refute html =~ "command output"
    refute html =~ "Recent runs"
    refute has_element?(view, "button[phx-click='run_history:toggle']")
  end

  test "run tab surfaces failure reason and retry affordance for failed local run", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-failed")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    run_id = Ledger.new_run_id()

    Ledger.command_requested(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id,
      plane: "safe_action",
      metadata: %{source: "ui", protocol: "devide.immediate.v1"}
    })

    Ledger.run_started(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id
    })

    Ledger.run_finished(:failed, %{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id,
      metadata: %{exit_code: 1}
    })

    {:ok, history} =
      History.start_run(%{
        id: run_id,
        workspace_id: "ws-1",
        actor_id: "dev",
        command_id: "test",
        started_at: DateTime.utc_now()
      })

    {:ok, _} =
      History.finish_run(history.id, %{
        status: :failed,
        exit_code: 1,
        started_at: history.started_at,
        finished_at: DateTime.utc_now(),
        output: "error output\n"
      })

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    html = open_run_panel(view)

    assert has_element?(view, "#run-failure-surface")
    assert html =~ "exit 1"
    assert has_element?(view, "#run-retry-btn")
    refute html =~ "Recent runs"
    refute has_element?(view, "button[phx-click='run_history:toggle']")
  end

  test "run tab hides retry for blocked run", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-denied")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    run_id = Ledger.new_run_id()

    decision = DevIDE.Policy.Decision.deny(:run_command, :manual, :not_allowed, %{})

    Ledger.command_denied(decision, %{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "badcmd",
      run_id: run_id,
      plane: "safe_action",
      metadata: %{source: "ui", protocol: "devide.immediate.v1"}
    })

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    html = open_run_panel(view)

    assert has_element?(view, "#run-failure-surface")
    assert html =~ "not_allowed"
    refute has_element?(view, "#run-retry-btn")
    refute html =~ "command output"
    refute html =~ "Recent runs"
    refute has_element?(view, "button[phx-click='run_history:toggle']")
  end

  test "show LiveView refuses non-local hosts politely (product.md §11)", %{conn: conn} do
    # The host gate fires before Workspaces.get/1, so no manager response
    # is needed. A non-local host id should redirect back to the picker
    # with an honest flash — "hide rather than mock".
    assert {:error, {:live_redirect, %{to: "/workspaces", flash: flash}}} =
             live(conn, ~p"/workspaces/abc?host=remote")

    assert flash["error"] =~ "Cross-host attach is not yet configured"
  end

  test "show LiveView opens known workspace links for non-owner forward-auth users", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-shared-link")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_forward_auth = Application.get_env(:dev_ide, :forward_auth)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :forward_auth, true)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:forward_auth, prev_forward_auth)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-auth-request-email") == ["viewer@example.com"]
      workspace_payload(conn, workspace_path)
    end)

    conn = Plug.Conn.put_req_header(conn, "x-auth-request-email", "viewer@example.com")

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    assert has_element?(view, "[data-workspace-id='ws-1']")
  end

  test "terminal output auto-opens the first detected preview without bar spam", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-preview-detect")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    send(view.pid, {:pty_data, "pane-1", "VITE ready in 120 ms: http://localhost:5173\n"})

    assert has_element?(view, "#preview-candidate-5173")

    broadcast_preview_pane(view, "%1", "http://localhost:5173")
    refute has_element?(view, "#preview-candidate-5173")

    send(view.pid, {:pty_data, "pane-1", "VITE ready in 120 ms: http://localhost:5174\n"})

    assert has_element?(view, "#preview-candidate-5174")
  end

  test "detected preview candidates are deduplicated by local origin", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-preview-dedupe")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    send(
      view.pid,
      {:pty_data, "pane-1",
       "http://localhost:5173 http://localhost:5173/workspaces localhost:5173\n"}
    )

    assert render(view) =~ "Detected preview"
    assert has_element?(view, "#preview-candidate-5173")
    refute has_element?(view, "#preview-candidate-5173-workspaces")
  end

  test "opening a detected preview keeps pane and session association", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-preview-open")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    send(view.pid, {:pty_data, "pane-1", "listening at http://localhost:5173\n"})
    assert has_element?(view, "#preview-candidate-5173")

    broadcast_preview_pane(view, "%1", "http://localhost:5173")
    refute has_element?(view, "#preview-candidate-5173")
    assert socket_assigns(view, :preview_panes)["%1"][:display_url] == "http://localhost:5173"

    send(view.pid, {:pty_data, "pane-1", "listening at http://localhost:5174\n"})
    assert has_element?(view, "#preview-candidate-5174")

    broadcast_preview_pane(view, "%2", "http://localhost:5174")
    refute has_element?(view, "#preview-candidate-5174")

    preview_panes = socket_assigns(view, :preview_panes)
    assert preview_panes["%2"][:display_url] == "http://localhost:5174"
    assert preview_panes["%1"][:display_url] == "http://localhost:5173"

    send(
      view.pid,
      {:preview_pane_removed, %{pane_id: "%2", workspace_id: "ws-1", preview_id: 1}}
    )

    _html = render(view)
    preview_panes = socket_assigns(view, :preview_panes)
    refute Map.has_key?(preview_panes, "%2")
    assert preview_panes["%1"][:display_url] == "http://localhost:5173"
  end

  test "detected preview candidates can be dismissed and remain hidden", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-preview-dismiss")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    send(view.pid, {:pty_data, "pane-1", "listening at http://localhost:5173\n"})
    broadcast_preview_pane(view, "%1", "http://localhost:5173")

    send(view.pid, {:pty_data, "pane-1", "listening at http://localhost:5174\n"})
    assert has_element?(view, "#preview-candidate-5174")

    view
    |> element("#preview-candidate-dismiss-5174")
    |> render_click()

    refute has_element?(view, "#preview-candidate-5174")

    send(view.pid, {:pty_data, "pane-1", "listening at http://localhost:5174\n"})
    refute has_element?(view, "#preview-candidate-5174")
  end

  test "opening a preview opens a control session and control events record audited actions", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-preview-control")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    push_tmux_topology!(view, ["%1"])
    broadcast_preview_pane(view, "%1", "http://localhost:5173")
    assert_preview_pane_overlay(view, "%1", "http://localhost:5173")
  end

  test "preview pane overlay appears on registration broadcast", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-preview-overlay")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_mode = Application.get_env(:dev_ide, :default_workspace_mode)
    prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :default_workspace_mode, :manual)
    Application.put_env(:dev_ide, :tmux_adapter, TmuxCtl.Test.FakeAdapter)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:default_workspace_mode, prev_mode)
      restore(:tmux_adapter, prev_tmux)
      TmuxCtl.Test.FakeState.delete(:fake_tmux_windows)
      TmuxCtl.Test.FakeState.delete(:fake_tmux_panes)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    session = socket_assigns(view, :tmux_session)
    pane = tmux_pane("/tmp")
    window = Map.put(tmux_window(0), :pane_list, [pane])

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{session => [window]})
    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{session => [pane]})

    send(
      view.pid,
      {DevIDE.Terminals.TmuxTopology,
       {:updated,
        %{
          session: session,
          windows: [window],
          panes: [pane],
          active_window_id: "@0",
          active_pane_id: "%0",
          version: 1,
          structure_version: 1
        }}}
    )

    _html = render(view)

    broadcast_preview_pane(view, "%0", "http://localhost:5173/agent")
    assert_preview_pane_overlay(view, "%0", "http://localhost:5173/agent")
  end

  test "selecting a preview pane does not move the terminal surface into its tile", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-preview-terminal-anchor")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_mode = Application.get_env(:dev_ide, :default_workspace_mode)
    prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :default_workspace_mode, :manual)
    Application.put_env(:dev_ide, :tmux_adapter, TmuxCtl.Test.FakeAdapter)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:default_workspace_mode, prev_mode)
      restore(:tmux_adapter, prev_tmux)
      TmuxCtl.Test.FakeState.delete(:fake_tmux_windows)
      TmuxCtl.Test.FakeState.delete(:fake_tmux_panes)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    session = socket_assigns(view, :tmux_session)

    panes = [
      tmux_pane_with_id("%1", active: true, left: 0, index: 0),
      tmux_pane_with_id("%2", active: false, left: 60, index: 1)
    ]

    window = Map.put(tmux_window(0), :pane_list, panes)

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{session => [window]})
    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{session => panes})

    send(
      view.pid,
      {DevIDE.Terminals.TmuxTopology,
       {:updated,
        %{
          session: session,
          windows: [window],
          panes: panes,
          active_window_id: "@0",
          active_pane_id: "%1",
          version: 1,
          structure_version: 1
        }}}
    )

    render(view)
    broadcast_preview_pane(view, "%2", "http://localhost:5173")

    assert has_element?(view, "#terminal-surface--1[data-terminal-surface='true']")
    refute has_element?(view, "#terminal-surface--2[data-terminal-surface='true']")

    panes =
      [
        tmux_pane_with_id("%1", active: false, left: 0, index: 0),
        tmux_pane_with_id("%2", active: true, left: 60, index: 1)
      ]

    window = Map.put(tmux_window(0), :pane_list, panes)

    send(
      view.pid,
      {DevIDE.Terminals.TmuxTopology,
       {:updated,
        %{
          session: session,
          windows: [window],
          panes: panes,
          active_window_id: "@0",
          active_pane_id: "%2",
          version: 2,
          structure_version: 2
        }}}
    )

    render(view)

    assert has_element?(view, "#terminal-surface--1[data-terminal-surface='true']")
    refute has_element?(view, "#terminal-surface--2[data-terminal-surface='true']")
    assert has_element?(view, "#tmux-pane--2[data-pane-active='true']")
    assert socket_assigns(view, :terminal_surface_pane_id) == "%1"
  end

  test "handle_info :preview_pane_registered assigns preview pane overlay state", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-preview-opened-msg")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)
    _ = DevIDE.PreviewControl.Registry.clear()

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      _ = DevIDE.PreviewControl.Registry.clear()
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    url = "http://localhost:5173/"
    broadcast_preview_pane(view, "%1", url)

    assert socket_assigns(view, :preview_panes)["%1"][:display_url] == url
  end

  defp socket_assigns(view, key) do
    :sys.get_state(view.pid).socket.assigns[key]
  end

  test "browser control broadcasts push reload events to workspace viewers", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-browser-control")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    assert {:ok, %{request_id: iframe_request_id}} =
             DevIDE.Agents.BrowserControl.reload_preview_iframe(%{id: "ws-1"},
               actor_id: "agent-1"
             )

    assert_push_event(view, "devide:reload_preview_iframes", %{
      "action" => "reload_preview_iframe",
      "actor_id" => "agent-1",
      "request_id" => ^iframe_request_id,
      "workspace_id" => "ws-1"
    })

    assert {:ok, %{request_id: page_request_id}} =
             DevIDE.Agents.BrowserControl.reload_page(%{id: "ws-1"}, actor_id: "agent-1")

    assert_push_event(view, "devide:reload_page", %{
      "action" => "reload_page",
      "actor_id" => "agent-1",
      "request_id" => ^page_request_id,
      "workspace_id" => "ws-1"
    })
  end

  test "file tree new-item form does not use native autofocus", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-tree-autofocus")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    render_click(view, "switch_tab", %{"tab" => "files"})
    render_click(view, "tree:new_form", %{"kind" => "file"})

    assert has_element?(view, "#tree-new-name-input[name='name']")
    refute has_element?(view, "#tree-new-name-input[autofocus]")
  end

  test "palette opens detected dev server preview", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-preview-palette")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    push_tmux_topology!(view, ["%1"])

    send(view.pid, {:pty_data, "pane-1", "http://localhost:5173\n"})
    _html = render(view)

    broadcast_preview_pane(view, "%1", "http://localhost:5173")
    assert_preview_pane_overlay(view, "%1", "http://localhost:5173")
  end

  test "untrusted preview URLs open as tabs without an iframe", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-preview-untrusted")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    Phoenix.LiveViewTest.render_click(view, "preview:open", %{
      "url" => "http://evil.example:4000",
      "mode" => "tab"
    })

    refute has_element?(view, "iframe[src='http://evil.example:4000']")
    assert DevIDE.Previews.list_for_workspace("ws-1") == []
  end

  defp workspace_index_payload(name) do
    %{
      "id" => name,
      "name" => name,
      "user" => "alice",
      "status" => "running",
      "type" => "v3",
      "branch" => "main"
    }
  end

  defp await_mount_hydration(view) do
    render_async(view, 5_000)
  end

  defp broadcast_preview_pane(view, pane_id, url, workspace_id \\ "ws-1") do
    send(
      view.pid,
      {:preview_pane_registered,
       %{
         pane_id: pane_id,
         workspace_id: workspace_id,
         url: url,
         display_url: url,
         preview_id: 1,
         control_session_id: 1,
         viewport: nil
       }}
    )

    render(view)
  end

  defp push_tmux_topology!(view, pane_ids) when is_list(pane_ids) do
    pane_ids = Enum.uniq(pane_ids)
    session = socket_assigns(view, :tmux_session)

    panes =
      case pane_ids do
        [single] ->
          [
            tmux_pane_with_id("%_spacer", active: false, left: 0, index: 0),
            tmux_pane_with_id(single, active: true, left: 60, index: 1)
          ]

        ids ->
          Enum.with_index(ids, fn id, idx ->
            tmux_pane_with_id(id, active: true, left: idx * 60, index: idx)
          end)
      end

    window = Map.put(tmux_window(0), :pane_list, panes)

    send(
      view.pid,
      {DevIDE.Terminals.TmuxTopology,
       {:updated,
        %{
          session: session,
          windows: [window],
          panes: panes,
          active_window_id: "@0",
          active_pane_id: List.last(pane_ids),
          version: 1,
          structure_version: 1
        }}}
    )

    render(view)
  end

  defp assert_preview_pane_overlay(view, pane_id, url) do
    dom_id = String.replace(pane_id, ~r/[^a-zA-Z0-9_-]/, "-")

    assert has_element?(
             view,
             "#preview-pane-#{dom_id} iframe[data-preview-iframe][src='#{url}']"
           )
  end

  defp open_run_panel(view) do
    render_click(view, "switch_tab", %{"tab" => "run"})
  end

  defp tmux_window(activity) do
    %{
      id: "@0",
      index: 0,
      name: "shell",
      active: true,
      panes: 1,
      activity: activity,
      current_command: "bash"
    }
  end

  defp tmux_pane(path) do
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
      current_path: path,
      activity: 0,
      activity_flag: false,
      bell: false,
      unseen_changes: false
    }
  end

  defp tmux_pane_with_id(id, opts \\ []) do
    path = Keyword.get(opts, :path, "/tmp")
    active = Keyword.get(opts, :active, true)
    left = Keyword.get(opts, :left, 0)
    index = Keyword.get(opts, :index, 0)

    tmux_pane(path)
    |> Map.put(:id, id)
    |> Map.put(:active, active)
    |> Map.put(:left, left)
    |> Map.put(:index, index)
  end

  defp workspace_payload(conn, workspace_path, workspace_name \\ "alpha", status \\ "running") do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "id" => "ws-1",
        "name" => workspace_name,
        "user" => "dev",
        "status" => status,
        "type" => "v3",
        "branch" => "main",
        "path" => workspace_path
      })
    )
  end

  @fake_state_keys ~w(fake_tmux_windows fake_tmux_panes fake_tmux_next_window fake_tmux_scrollback fake_tmux_test_pid)a

  defp restore(k, v) when k in @fake_state_keys, do: TmuxCtl.Test.FakeState.restore(k, v)
  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)

  defp kill_tmux_sessions_with_prefix(prefix) when is_binary(prefix) do
    with executable when is_binary(executable) <- System.find_executable("tmux"),
         {sessions, 0} <-
           System.cmd(executable, ["list-sessions", "-F", "\#{session_name}"],
             stderr_to_stdout: true
           ) do
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

  defp kill_tmux_session(session) when is_binary(session) do
    _ = System.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)
    :ok
  end

  defp kill_tmux_session(_), do: :ok
end
