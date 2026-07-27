defmodule CaseinWeb.WorkspaceLiveTest do
  use CaseinWeb.ConnCase, async: false

  # Not imported: `Phoenix.ChannelTest.connect/2` collides with ConnTest's
  # HTTP CONNECT verb macro and `push/3` with `Plug.Conn.push/3` (both
  # imported via ConnCase). The few channel calls below are fully qualified.
  require Phoenix.ChannelTest
  import Phoenix.LiveViewTest

  alias Casein.ArtifactProjects
  alias Casein.Audit
  alias Casein.Integrations.Manager.Client
  alias Casein.Runs.Ledger
  alias Casein.Terminals.Templates
  alias Casein.Workspaces.State.MemoryAdapter

  setup do
    alpha_tmux_prefix = Casein.Terminals.Tmux.workspace_session_prefix("alpha")

    kill_tmux_sessions_with_prefix(alpha_tmux_prefix)
    MemoryAdapter.clear()
    Audit.clear()
    Casein.Runtimes.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      Casein.Runtimes.clear()
      kill_tmux_sessions_with_prefix(alpha_tmux_prefix)
    end)

    :ok
  end

  test "allows cockpit mount for another user's folder workspace (flat peer model)", %{
    conn: conn
  } do
    root = Path.join(System.tmp_dir!(), "casein-folder-peer-#{System.unique_integer()}")
    alice_project = Path.join([root, "alice", "proj"])
    File.mkdir_p!(alice_project)

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore(:workspaces_root, prev_root)
    end)

    folder_id = "folder:" <> Base.url_encode64(alice_project, padding: false)

    assert {:ok, _view, _html} = live(conn, ~p"/workspaces/#{folder_id}")
  end

  test "terminal tab renders tmux windows as actionable tabs", %{conn: conn} do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-tmux-tabs")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_fake_tmux_next_window = TmuxCtl.Test.FakeState.get(:fake_tmux_next_window)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "alpha-#{System.unique_integer([:positive])}"
    tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev")
    extra_tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev-extra")
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
    flush_mailbox()

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
      restore(:fake_tmux_next_window, prev_fake_tmux_next_window)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path, workspace_name)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?window=@1")
    await_mount_hydration(view)

    assert_receive {:fake_tmux_select_window, ^tmux_session, "@1"}

    # The deep-link switch happened during mount, before this LiveView could
    # remember any socket-local history. C-b l must still use tmux's native
    # session history and toggle @1 -> @0 -> @1.
    render_click(view, "tmux:last_window", %{})
    assert_receive {:fake_tmux_last_window, ^tmux_session}
    assert_patch(view, "/workspaces/ws-1?session=u-dev&window=%400")
    assert_push_event(view, "terminal:focus_active", %{"reason" => "tmux:last_window"})

    render_click(view, "tmux:last_window", %{})
    assert_receive {:fake_tmux_last_window, ^tmux_session}
    assert_patch(view, "/workspaces/ws-1?session=u-dev&window=%401&pane=%251")

    assert has_element?(view, "#attention-surface-ws-1")
    assert has_element?(view, "#tmux-window-tabs-ws-1")
    assert has_element?(view, "#mobile-key-bar-ws-1[phx-hook='MobileKeyBar']")
    assert has_element?(view, "#mobile-key-bar-scroll-ws-1")

    render_hook(view, "sidebar:open", %{"mode" => "both"})

    # The default/landing session is a normal row marked "home" (no separate shell entry).
    assert has_element?(view, "#active_sessions-u-dev")
    assert has_element?(view, "#active_sessions-u-dev [aria-label='Home session']")
    assert has_element?(view, "[phx-value-session-id='u-dev-extra']")
    refute has_element?(view, "[phx-value-session-id='u-dev-extra']", "Shell")
    render_click(view, "terminal:cycle_session", %{"dir" => "next"})
    assert_patch(view, "/workspaces/ws-1?session=u-dev-extra&window=%400")
    assert_push_event(view, "terminal:focus_active", %{"reason" => "terminal:cycle_session"})

    render_click(view, "terminal:cycle_session", %{"dir" => "prev"})
    assert_patch(view, "/workspaces/ws-1?session=u-dev&window=%401&pane=%251")
    assert_push_event(view, "terminal:focus_active", %{"reason" => "terminal:cycle_session"})

    view
    |> element("#active_sessions-u-dev-extra")
    |> render_click()

    assert_patch(view, "/workspaces/ws-1?session=u-dev-extra&window=%400")
    refute_received {:fake_tmux_select_window, ^extra_tmux_session, "@0"}

    assert has_element?(
             view,
             "[phx-value-session-id='u-dev-extra'][class*='text-primary']"
           )

    # Attach the other session on a specific window (window rows live in the
    # WINDOWS column starting Slice 2; until then use attach directly).
    render_click(view, "attach_terminal_session", %{
      "session-id" => "u-dev-extra",
      "tmux-session" => extra_tmux_session,
      "window-id" => "@0"
    })

    assert_receive {:fake_tmux_select_window, ^extra_tmux_session, "@0"}
    assert_patch(view, "/workspaces/ws-1?session=u-dev-extra&window=%400")

    assert has_element?(view, "#tmux-window--0 a", "scratch")
    refute has_element?(view, "#tmux-window--1 a", "tests")

    render_hook(view, "sidebar:open", %{"mode" => "both"})

    view
    |> element("#active_sessions-u-dev")
    |> render_click()

    assert_patch(view, "/workspaces/ws-1?session=u-dev&window=%401&pane=%251")
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
    assert has_element?(view, "#tmux-pane--2[title$='apps/web · iex']")

    view
    |> element("#tmux-pane--2")
    |> render_click()

    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%2"}
    assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%2']")

    assert_push_event(view, "terminal:focus_active", %{
      "reason" => "tmux:select_pane",
      "tmux_pane_id" => "%2"
    })

    assert has_element?(view, "#tmux-pane--1[data-pane-active='false']")
    assert has_element?(view, "#tmux-pane--2[data-pane-active='true']")
    assert has_element?(view, "#tmux-window--1 a[title*='apps/web · iex']")

    # The per-pane HUD buttons (kill / split / resize arrows) were removed in
    # commit 7e22bac; their tmux:* event handlers remain, now driven by key
    # bindings. Dispatch those events directly here, as the resize assertions
    # further down already do.
    render_click(view, "tmux:kill_pane", %{"pane-id" => "%1"})

    assert_receive {:fake_tmux_kill_pane, ^tmux_session, "%1"}
    assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%2']")

    assert_push_event(view, "terminal:focus_active", %{
      "reason" => "tmux:kill_pane",
      "tmux_pane_id" => "%2"
    })

    refute has_element?(view, "#tmux-pane--1")
    assert has_element?(view, "#tmux-pane--2[data-pane-active='true']")
    assert has_element?(view, "#tmux-pane--3[data-pane-active='false']")

    split_layout_version =
      :sys.get_state(view.pid).socket.assigns.tmux_topology_layout_version

    render_click(view, "tmux:split_pane", %{"pane-id" => "%3", "direction" => "v"})

    render_hook(view, "pane:commit_split", %{
      "pane_id" => "%3",
      "direction" => "v",
      "base_layout_version" => split_layout_version
    })

    assert_receive {:fake_tmux_split_pane, ^tmux_session, "%3", "v", "%4"}
    assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%4']")

    assert_push_event(view, "terminal:focus_active", %{
      "reason" => "split_pane",
      "tmux_pane_id" => "%4"
    })

    assert has_element?(view, "#tmux-pane--2[data-pane-active='false']")
    assert has_element?(view, "#tmux-pane--3[data-pane-active='false']")
    assert has_element?(view, "#tmux-pane--4[data-pane-active='true']")

    split_html = view |> element("#tmux-pane--4") |> render()
    assert split_html =~ "top: 75.0%;"
    assert split_html =~ "height: 25.0%;"

    render_click(view, "tmux:resize_pane", %{
      "pane-id" => "%3",
      "direction" => "down",
      "amount" => "5"
    })

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

    assert has_element?(
             view,
             "#tmux-pane--2[data-pane-left='60'][data-pane-width='60'][data-pane-height='40']"
           )

    render_click(view, "tmux:resize_pane_step", %{
      "pane-id" => "%3",
      "direction" => "down",
      "amount" => "2"
    })

    assert_receive {:fake_tmux_resize_pane, ^tmux_session, "%3", "down", 2}

    render_click(view, "tmux:resize_pane_finish", %{})
    assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%4']")

    # Hidden leader-key targets render for C-b dispatch (see the dedicated
    # "leader-key dispatch targets" test for the full contract).
    assert has_element?(view, "button[data-leader-action='detach']")
    assert has_element?(view, "button[data-leader-action='palette']")
    assert has_element?(view, "button[data-leader-action='help']")
    assert has_element?(view, "button[data-leader-action='last-window']")
    assert has_element?(view, "button[data-leader-action='last-pane']")
    assert has_element?(view, "button[data-leader-action='kill-window'][phx-value-window-id]")
    assert has_element?(view, "button[data-leader-action='rename-window'][phx-value-window-id]")
    # The default/landing session is now a normal renamable session, so its
    # leader-key rename target renders even when it is the active session.
    assert has_element?(view, "button[data-leader-action='rename-session'][phx-value-session-id]")

    for action <- ~w(pane-left pane-down pane-up pane-right pane-next) do
      assert has_element?(
               view,
               "button[data-leader-action='#{action}'][phx-click='pane:navigate']"
             )
    end

    assert has_element?(
             view,
             "button[data-leader-action='pane-swap-previous'][phx-click='pane:swap_previous']"
           )

    assert has_element?(
             view,
             "button[data-leader-action='pane-swap-next'][phx-click='pane:swap_next']"
           )

    assert has_element?(view, "#leader-cheatsheet")
    help_html = render(view)
    assert help_html =~ "casein agent auth signin codex"
    assert help_html =~ "casein agent auth signin claude"
    assert help_html =~ "Casein detects the owner"
    assert help_html =~ "casein agent auth status"
    # Inline next/prev window chips lived on the removed dropdown; cycling uses
    # hidden leader targets and the always-visible tab bar.
    refute has_element?(view, ".leader-key-control[data-shortcut='Ctrl + B, then N']")

    # Last window moved from an inline clock button to the ⋯ overflow menu.
    assert has_element?(view, ".header-overflow button[phx-click='tmux:last_window']")

    # Both rails advertise leader second-keys while open (C-b s / C-b w).
    assert has_element?(view, ".leader-key-control[data-shortcut='Ctrl + B, then S']")
    assert has_element?(view, ".leader-key-control[data-shortcut='Ctrl + B, then W']")
    # Pickers layer over the terminal instead of becoming flex siblings that
    # shrink its viewport and trigger a Ghostty/tmux resize cycle.
    assert has_element?(
             view,
             "[data-terminal-picker-overlay].absolute.inset-y-0.left-0 > [data-sessions-picker-sidebar]"
           )

    assert has_element?(
             view,
             "[data-terminal-picker-overlay] > [data-window-picker-sidebar]"
           )

    assert has_element?(
             view,
             "[data-terminal-picker-overlay] + [data-terminal-viewport]"
           )

    # Focus mode lives on the sessions rail (not the header).
    assert has_element?(view, "#sessions-focus-mode-ws-1")

    render_hook(view, "sidebar:open", %{"mode" => "windows"})

    assert has_element?(
             view,
             "[data-window-picker-sidebar][data-shortcut='Ctrl + B, then W']"
           )

    # windows-only mode closes the sessions rail (and its focus control).
    refute has_element?(view, "#sessions-focus-mode-ws-1")

    render_hook(view, "sidebar:close", %{})
    refute has_element?(view, "button[data-shortcut='Ctrl/Cmd + Shift + F']")
    # No summoned rails → no click-away scope lingering in the DOM.
    refute has_element?(view, "#terminal-picker-overlay-ws-1")

    render_hook(view, "sidebar:open", %{"mode" => "both"})
    assert has_element?(view, "#sessions-focus-mode-ws-1[data-shortcut='Ctrl/Cmd + Shift + F']")
    # Both rails share one click-away scope so a click outside both dismisses the
    # whole picker (sidebar:close), while clicks between the two rails are contained.
    assert has_element?(view, "#terminal-picker-overlay-ws-1[phx-click-away='sidebar:close']")

    cheatsheet_html = render(view)
    assert cheatsheet_html =~ "Ctrl+P"
    assert cheatsheet_html =~ "show pane numbers"
    assert cheatsheet_html =~ "Inside the command palette"

    # C-b l continues to use tmux history after an ordinary tab switch.
    render_click(view, "tmux:select_window", %{"window-id" => "@0"})
    assert_receive {:fake_tmux_select_window, ^tmux_session, "@0"}
    assert_patch(view, "/workspaces/ws-1?session=u-dev&window=%400")

    render_click(view, "tmux:last_window", %{})
    assert_receive {:fake_tmux_last_window, ^tmux_session}
    assert_patch(view, "/workspaces/ws-1?session=u-dev&window=%401&pane=%252")

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
    assert has_element?(view, "#tmux-window--1", "ci")

    view
    |> element("#tmux-window-tabs-ws-1 button[aria-label='New tmux window']")
    |> render_click()

    assert_receive {:fake_tmux_ensure_session, ^tmux_session, ^workspace_path}
    assert_receive {:fake_tmux_new_window, ^tmux_session, _opts}
    assert_patch(view, "/workspaces/ws-1?session=u-dev&window=%402")
    assert_push_event(view, "terminal:focus_active", %{"reason" => "tmux:new_window"})

    view
    |> element("#tmux-window--0 button[title='Close tmux window']")
    |> render_click()

    assert_receive {:fake_tmux_kill_window, ^tmux_session, "@0"}
    assert_push_event(view, "terminal:focus_active", %{"reason" => "tmux:kill_window"})
    refute has_element?(view, "#tmux-window--0")

    render_hook(view, "sidebar:open", %{"mode" => "both"})

    view
    |> element("#active_sessions-u-dev-extra")
    |> render_click()

    assert_patch(view, "/workspaces/ws-1?session=u-dev-extra&window=%400")

    # The active session is now a non-default session, so the leader-key
    # rename-session target renders for it.
    assert has_element?(
             view,
             "button[data-leader-action='rename-session'][phx-value-session-id='u-dev-extra']"
           )

    # Session rename: pencil opens the inline form, submit sets the tmux alias
    # and the re-scan surfaces it as the session label.
    view
    |> element("button[data-leader-action='rename-session'][phx-value-session-id='u-dev-extra']")
    |> render_click()

    assert has_element?(view, "#session-rename-form-active_sessions-u-dev-extra")

    view
    |> form("#session-rename-form-active_sessions-u-dev-extra", %{
      "session" => %{"name" => "billing"}
    })
    |> render_submit()

    assert_receive {:fake_tmux_set_session_alias, ^extra_tmux_session, "billing"}
    # Alias surfaces on the sessions rail (header session title is gone).
    assert has_element?(view, "#sessions-sidebar-ws-1", "billing")

    render_click(view, "tmux:kill_window", %{"window-id" => "@0"})
    refute_received {:fake_tmux_kill_window, ^extra_tmux_session, "@0"}
    assert render(view) =~ "Cannot close the last tmux window."
  end

  test "leader-key dispatch targets are unique and survive focus mode", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-leader-targets")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "leader-#{System.unique_integer([:positive])}"
    tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev")
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

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path, workspace_name)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1")
    await_mount_hydration(view)

    # A session with no previous window still invokes native tmux history, but
    # tmux's `no last window` response remains a quiet no-op.
    render_click(view, "tmux:last_window", %{})
    assert_receive {:fake_tmux_last_window, ^tmux_session}
    assert socket_assigns(view, :tmux_active_window_id) == "@0"
    refute render(view) =~ "Could not select last tmux window"

    # Every dispatch-only WorkspaceLeader action has a hidden target.
    for action <-
          ~w(detach palette help last-window last-pane prev-session next-session next-window prev-window) do
      assert has_element?(view, "button[data-leader-action='#{action}']")
    end

    for action <- ~w(pane-left pane-down pane-up pane-right pane-next) do
      assert has_element?(
               view,
               "button[data-leader-action='#{action}'][phx-click='pane:navigate']"
             )
    end

    assert has_element?(
             view,
             "button[data-leader-action='pane-swap-previous'][phx-click='pane:swap_previous']"
           )

    assert has_element?(
             view,
             "button[data-leader-action='pane-swap-next'][phx-click='pane:swap_next']"
           )

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
    refute has_element?(view, "#tmux-window-tabs-ws-1")

    for action <-
          ~w(detach palette help last-window last-pane prev-session next-session next-window prev-window) do
      assert has_element?(view, "button[data-leader-action='#{action}']")
    end

    for action <- ~w(pane-left pane-down pane-up pane-right pane-next) do
      assert has_element?(view, "button[data-leader-action='#{action}']")
    end

    for action <- ~w(pane-swap-previous pane-swap-next) do
      assert has_element?(view, "button[data-leader-action='#{action}']")
    end

    assert has_element?(view, "button[data-leader-action='kill-window']")
    assert has_element?(view, "button[data-leader-action='rename-window']")
  end

  test "session bar folds owned workspace sessions and hides teammate sessions", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-owned-session-bar")
    workspace_path = Path.join(workspace_root, "current")
    owned_path = Path.join(workspace_root, "owned")
    teammate_path = Path.join(workspace_root, "teammate")
    File.mkdir_p!(workspace_path)
    File.mkdir_p!(owned_path)
    File.mkdir_p!(teammate_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_user = Application.get_env(:casein, :current_user)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

    Application.put_env(:casein, :current_user, %{
      id: "alice",
      username: "alice",
      email: "alice@example.com",
      role: :owner
    })

    current_tmux = Casein.Terminals.Tmux.session_name("alpha", "u-alice")
    owned_tmux = Casein.Terminals.Tmux.session_name("alice-owned", "u-alice-owned")
    owned_tmux2 = Casein.Terminals.Tmux.session_name("alice-owned", "u-alice-owned-2")
    # The owned workspace's landing (home) shell folds away in the cross-workspace
    # tree; a newer home shell keeps the two `u-alice-owned*` shells as real,
    # navigable folded sessions to assert on.
    owned_home_tmux = Casein.Terminals.Tmux.session_name("alice-owned", "u-alice-owned-home")
    teammate_tmux = Casein.Terminals.Tmux.session_name("bob-owned", "u-bob-owned")
    activity_now = DateTime.utc_now() |> DateTime.to_unix()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      current_tmux => [tmux_window(activity_now)],
      owned_tmux => [tmux_window(activity_now)],
      owned_tmux2 => [tmux_window(activity_now)],
      owned_home_tmux => [tmux_window(activity_now + 100)],
      teammate_tmux => [tmux_window(activity_now)]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      current_tmux => [tmux_pane(workspace_path)],
      owned_tmux => [tmux_pane(owned_path)],
      owned_tmux2 => [tmux_pane(owned_path)],
      owned_home_tmux => [tmux_pane(owned_path)],
      teammate_tmux => [tmux_pane(teammate_path)]
    })

    _ =
      Casein.Workspaces.State.sync(%Casein.Workspace{
        id: "owned-ws",
        name: "alice-owned",
        user: "alice",
        status: :running,
        path: owned_path,
        metadata: %{raw: %{"user" => "alice"}}
      })

    _ =
      Casein.Workspaces.State.sync(%Casein.Workspace{
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

    Req.Test.stub(Casein.Integrations.Manager.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/workspaces/ws-1/status"
      workspace_payload(conn, workspace_path, "alpha", "running", "alice")
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    refute has_element?(view, "#workspace-session-rail")

    # Cross-workspace navigation now lives in the summoned SESSIONS sidebar: the
    # owned workspace shows as a node whose sessions load (and fold in) on expand,
    # while a teammate's workspace never appears at all.
    render_hook(view, "sidebar:open", %{"mode" => "both"})
    render_async(view)

    # The owned workspace surfaces as its own sidebar node; expanding it folds in
    # its (non-home) sessions.
    assert has_element?(view, "[data-picker-sessions-id='sidebar-ws-owned-ws']")

    render_hook(view, "sidebar:toggle_workspace", %{"workspace-id" => "owned-ws"})

    # The rail warm-up (kicked off by sidebar:open, settled by render_async
    # above) already cached owned-ws sessions, so expansion renders instantly —
    # no second async round-trip before the rows are visible.
    assert has_element?(view, "#active_sessions-u-alice-owned")

    render_async(view)

    assert has_element?(view, "#active_sessions-u-alice-owned")

    refute has_element?(view, "#active_sessions-u-alice-owned", "Shell")

    assert has_element?(view, "a[href*='/workspaces/owned-ws'][href*='session=u-alice-owned']")
    refute has_element?(view, "a[href*='/workspaces/teammate-ws']")
  end

  test "session tabs keep sibling browser tab shells and explicit shells", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-stale-browser-tabs")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "alpha"
    current_sid = "u-dev-abcd1234"
    stale_sid = "u-dev-deadbeef"
    explicit_sid = "u-dev-extra"
    current_tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, current_sid)
    stale_tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, stale_sid)
    explicit_tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, explicit_sid)
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

    {:ok, _} = Registry.register(Casein.Terminals.Registry, {"ws-1", stale_sid}, nil)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path, workspace_name)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    conn = put_connect_params(conn, %{"tab_id" => "abcd1234"})
    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    # Session rows (home marker, browser-tab shells, explicit shells) live in the
    # summoned SESSIONS sidebar now.
    render_hook(view, "sidebar:open", %{"mode" => "both"})

    assert has_element?(view, "[aria-label='Home session']")
    assert has_element?(view, "[phx-value-session-id='#{stale_sid}']")
    assert has_element?(view, "[phx-value-session-id='#{explicit_sid}']")

    # A session appearing elsewhere reaches this viewer via the directory
    # broadcast — no click on the refresh button involved.
    second_sid = "u-dev-second"
    second_tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, second_sid)

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

    _ = Casein.Terminals.SessionDirectory.refresh_now("ws-1", workspace_name: workspace_name)

    assert has_element?(view, "[phx-value-session-id='#{second_sid}']")
    assert has_element?(view, "[phx-value-session-id='#{stale_sid}']")
  end

  test "stale terminal session tab shows friendly error without switching", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-stale-session")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "stale-#{System.unique_integer([:positive])}"
    tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev")

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

    {:ok, _} = Registry.register(Casein.Terminals.Registry, {"ws-1", "u-dev-stale"}, nil)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path, workspace_name)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    # The stale session row lives in the summoned SESSIONS sidebar.
    render_hook(view, "sidebar:open", %{"mode" => "both"})

    assert has_element?(view, "[phx-value-session-id='u-dev-stale']")

    view
    |> element("[phx-value-session-id='u-dev-stale']")
    |> render_click()

    assert has_element?(view, "#flash-error", "Terminal session ended. Refreshed sessions.")
    assert has_element?(view, "[data-picker-active] [aria-label='Home session']")
  end

  test "shared session URL silently drops into a live session when the session is gone", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-dead-link")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "dead-link-#{System.unique_integer([:positive])}"
    tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev")

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

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path, workspace_name)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} =
      live(conn, ~p"/workspaces/ws-1?session=u-dev-missing&window=@166")

    await_mount_hydration(view)

    # No recovery banner and no error flash — just drop into the live (Home) session.
    refute has_element?(view, "#view-link-notice")
    refute has_element?(view, "#flash-error")

    assert_patch(view, "/workspaces/ws-1?session=u-dev&window=%400")

    # The active-session marker now lives in the summoned SESSIONS sidebar.
    render_hook(view, "sidebar:open", %{"mode" => "both"})
    assert has_element?(view, "[data-picker-active] [aria-label='Home session']")
  end

  test "pane and zoom deep link restores view state", %{conn: conn} do
    workspace_root = Path.join(System.tmp_dir!(), "casein-pane-deep-link")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "pane-link-#{System.unique_integer([:positive])}"
    tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev")

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{
          id: "@0",
          index: 0,
          name: "agent",
          active: true,
          panes: 2,
          activity: 0,
          current_command: "bash"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        tmux_pane_with_id("%0", path: workspace_path, active: true, index: 0),
        tmux_pane_with_id("%1", path: workspace_path, active: false, index: 1)
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

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path, workspace_name)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} =
      live(conn, ~p"/workspaces/ws-1?session=u-dev&window=%400&pane=%1&zoom=1")

    await_mount_hydration(view)

    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%1"}
    assert_receive {:fake_tmux_zoom_pane, ^tmux_session, "%1"}
    assert socket_assigns(view, :tmux_active_pane_id) == "%1"
    assert socket_assigns(view, :window_zoomed?) == true
  end

  test "stale terminal session marks raw pane ended instead of leaving spinner", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-raw-stale-session")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())
    {:ok, _} = Casein.Workspaces.State.set_mode("ws-1", :manual)

    workspace_name = "raw-stale-#{System.unique_integer([:positive])}"
    tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev")

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

    {:ok, _} = Registry.register(Casein.Terminals.Registry, {"ws-1", "u-dev-stale"}, nil)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_test_pid, prev_fake_tmux_pid)
      restore(:fake_tmux_windows, prev_fake_tmux_windows)
      restore(:fake_tmux_panes, prev_fake_tmux_panes)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path, workspace_name)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    # The stale session row lives in the summoned SESSIONS sidebar.
    render_hook(view, "sidebar:open", %{"mode" => "both"})

    view
    |> element("[phx-value-session-id='u-dev-stale']")
    |> render_click()

    assert has_element?(view, "#flash-error", "Terminal session ended. Refreshed sessions.")
    assert :sys.get_state(view.pid).socket.assigns.pane_data["pane-1"].error == :session_ended
  end

  test "stopped workspace does not block host-backed raw terminal", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-stopped-workspace-terminal")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    {:ok, _} = Casein.Workspaces.State.set_mode("ws-1", :manual)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path, "alpha", "stopped")

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    assert has_element?(view, "#workspace-start-menu-button", "Start workspace")
    refute has_element?(view, "#terminal-workspace-start-button")
    refute has_element?(view, "#terminal-workspace-start-unavailable")
    refute has_element?(view, "[role='alert']", "Terminal failed to start")
  end

  test "workspace start failure shows manager message without raw http tuple", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-bespoke-workspace-start")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    {:ok, _} = Casein.Workspaces.State.set_mode("ws-1", :manual)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux_adapter)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path, "alpha", "stopped")

      %Plug.Conn{method: "POST", path_info: ["api", "workspaces", "ws-1", "start"]} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          500,
          Jason.encode!(%{
            "error" =>
              "Bespoke workspaces do not use the MILC Docker start flow. Open OpenCode or use the deploy command shown on the card."
          })
        )

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    view
    |> element("#workspace-start-menu-button")
    |> render_click()

    assert has_element?(view, "#flash-error", "Bespoke workspaces do not use")
    refute has_element?(view, "#flash-error", "{:http")
  end

  test "terminal image paste event saves the image under the workspace clipboard", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-image-paste")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)

    {:ok, _} = Casein.Workspaces.State.set_mode("ws-1", :manual)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
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
          ".casein",
          "clipboard",
          "*-dropped-image.png"
        ])
      )

    assert File.read!(path) == "png bytes"
  end

  test "authz gate denies an unregistered event and audits the denial", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-authz-gate")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    # An event with no handle_event clause would crash the LiveView if it
    # reached the router — the gate must halt it before that, surface a flash,
    # and record a policy.blocked audit event. (render_hook returning at all
    # proves the event was halted rather than dispatched.)
    render_hook(view, "totally:made_up_event", %{})

    assert has_element?(view, "#flash-error", "That action isn't available here.")

    assert [%{decision: :deny, reason: :unknown_action, target_ref: "totally:made_up_event"}] =
             Audit.recent_for("ws-1", 10)
             |> Enum.filter(&(&1.action == "policy.blocked"))

    # A registered event passes the gate: it reaches its handler (switch_tab
    # would crash if the gate had halted it) and adds no new policy.blocked deny.
    render_hook(view, "switch_tab", %{"tab" => "files"})

    blocked = Enum.filter(Audit.recent_for("ws-1", 10), &(&1.action == "policy.blocked"))
    assert length(blocked) == 1

    # Regression: the ContextMenu hook's ctx:open must pass the gate — it
    # shipped without being registered in @known_events, so every right-click
    # menu in the cockpit was denied with the unknown-action flash.
    render_hook(view, "ctx:open", %{
      "menu" => "window_tab",
      "ctx" => %{"windowId" => "@1"},
      "x" => 10,
      "y" => 10
    })

    assert has_element?(view, "#ctx-menu")

    blocked = Enum.filter(Audit.recent_for("ws-1", 10), &(&1.action == "policy.blocked"))
    assert length(blocked) == 1

    render_hook(view, "ctx:close", %{})
    refute has_element?(view, "#ctx-menu")
  end

  test "split OSC52 terminal output pushes clipboard write event", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-osc52-copy")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    on_exit(fn -> File.rm_rf(workspace_root) end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    text = "copied from claude"
    b64 = Base.encode64(text)

    send(view.pid, {:pty_data, "pane-1", "\x1b]"})
    send(view.pid, {:pty_data, "pane-1", "52;c;" <> binary_part(b64, 0, 5)})
    send(view.pid, {:pty_data, "pane-1", binary_part(b64, 5, byte_size(b64) - 5) <> "\x07"})

    assert_push_event(view, "clipboard:write", %{"text" => ^text})
  end

  test "terminal palette previews and applies a built-in tmux session template", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-template-palette")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_fake_tmux_next_window = TmuxCtl.Test.FakeState.get(:fake_tmux_next_window)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "alpha-#{System.unique_integer([:positive])}"
    tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev")

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

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path, workspace_name)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
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

    assert_patch(view, "/workspaces/ws-1?session=u-dev&window=%402&pane=%252")
    refute has_element?(view, "#template-preview-modal")
    assert has_element?(view, "#tmux-window--2")
    assert has_element?(view, "#tmux-pane-layout-ws-1[data-active-pane-id='%2']")
    # Per-pane titlebars were removed (1bd36c6); the command now lives in the
    # pane tile's title attribute, while the tmux-composited surface renders it.
    assert has_element?(view, "#tmux-pane--3[title$='git status --short']")

    event =
      Audit.recent_for("ws-1", 10)
      |> Enum.find(&match?(%{action: "tmux.template_applied", target_ref: "generic_project"}, &1))

    assert event

    assert event.target_type == "tmux_template"
    assert event.actor_id == "dev"
    assert event.metadata.session == tmux_session
    assert event.metadata.step_count == 5
    assert event.metadata.refs["pane:shell:root"] == "%2"
  end

  test "session recovery only re-applies the template to its own empty session", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-recovery-template")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_fake_tmux_next_window = TmuxCtl.Test.FakeState.get(:fake_tmux_next_window)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "alpha-#{System.unique_integer([:positive])}"
    tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev")

    empty_window = %{
      id: "@1",
      index: 0,
      name: "main",
      active: true,
      panes: 1,
      activity: DateTime.utc_now() |> DateTime.to_unix(),
      current_command: "bash"
    }

    root_pane = %{
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

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{tmux_session => [empty_window]})
    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{tmux_session => [root_pane]})
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

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path, workspace_name)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    notice = fn session ->
      {:terminal_recovery,
       %{
         type: :session_recreated,
         workspace_id: "ws-1",
         sid: "u-dev",
         tmux_session: session,
         reason: :session_missing_on_recover,
         history_restored?: false,
         template_id: "agent_pair"
       }}
    end

    # A notice about some *other* session in this workspace must not mutate the
    # session this viewer is driving. A session whose worktree is gone recreates
    # and dies on every drift tick, and each notice used to append an
    # `agent_pair` "work" window here — forever.
    send(view.pid, notice.("casein_#{workspace_name}_wt-gone-elsewhere"))
    refute_receive {:fake_tmux_new_window, ^tmux_session, _}, 800

    # Our own session, but it already carries a layout: applying is purely
    # additive, so leave it alone rather than duplicating the template windows.
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [empty_window, %{empty_window | id: "@2", index: 1, name: "work"}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session => [root_pane, %{root_pane | id: "%2", window_id: "@2", index: 1}]
    })

    send(view.pid, notice.(tmux_session))
    refute_receive {:fake_tmux_new_window, ^tmux_session, _}, 800

    # Our own session, recreated empty: restore the layout.
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{tmux_session => [empty_window]})
    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{tmux_session => [root_pane]})

    send(view.pid, notice.(tmux_session))
    assert_receive {:fake_tmux_new_window, ^tmux_session, new_window_opts}, 2_000
    assert new_window_opts[:name] == "work"
  end

  test "template library saves previews applies and deletes exported layouts", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-template-library")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_tmux_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_tmux_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_fake_tmux_next_window = TmuxCtl.Test.FakeState.get(:fake_tmux_next_window)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    workspace_name = "alpha-#{System.unique_integer([:positive])}"
    tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev")

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

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path, workspace_name)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

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

  test "show LiveView refuses non-local hosts politely (product.md §11)", %{conn: conn} do
    # The host gate fires before Workspaces.get/1, so no manager response
    # is needed. A non-local host id should redirect back to the picker
    # with an honest flash — "hide rather than mock".
    assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
             live(conn, ~p"/workspaces/abc?host=remote")

    assert flash["error"] =~ "Cross-host attach is not yet configured"
  end

  test "show LiveView opens known workspace links for non-owner forward-auth users", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-shared-link")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_forward_auth = Application.get_env(:casein, :forward_auth)
    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :forward_auth, true)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:forward_auth, prev_forward_auth)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        assert Plug.Conn.get_req_header(conn, "x-auth-request-email") == ["viewer@example.com"]
        workspace_payload(conn, workspace_path, "alpha", "running", "viewer")

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    conn = Plug.Conn.put_req_header(conn, "x-auth-request-email", "viewer@example.com")

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    assert has_element?(view, "#workspace-header-ws-1")
  end

  test "terminal output does not render detected preview controls", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-preview-detect")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    send(view.pid, {:pty_data, "pane-1", "VITE ready in 120 ms: http://localhost:5173\n"})

    refute render(view) =~ "Detected preview"
    refute has_element?(view, "#preview-candidate-5173")
    assert socket_assigns(view, :preview_panes) == %{}

    broadcast_preview_pane(view, "%1", "http://localhost:5173")
    refute has_element?(view, "#preview-candidate-5173")

    send(view.pid, {:pty_data, "pane-1", "VITE ready in 120 ms: http://localhost:5174\n"})

    refute has_element?(view, "#preview-candidate-5174")
  end

  test "terminal output with repeated preview URLs stays out of terminal chrome", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-preview-dedupe")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    send(
      view.pid,
      {:pty_data, "pane-1",
       "http://localhost:5173 http://localhost:5173/workspaces localhost:5173\n"}
    )

    refute render(view) =~ "Detected preview"
    refute has_element?(view, "#preview-candidate-5173")
    refute has_element?(view, "#preview-candidate-5173-workspaces")
    assert socket_assigns(view, :preview_panes) == %{}
  end

  test "agent-created preview panes keep pane and session association", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-preview-open")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    send(view.pid, {:pty_data, "pane-1", "listening at http://localhost:5173\n"})
    refute has_element?(view, "#preview-candidate-5173")

    broadcast_preview_pane(view, "%1", "http://localhost:5173")
    refute has_element?(view, "#preview-candidate-5173")
    assert socket_assigns(view, :preview_panes)["%1"][:display_url] == "http://localhost:5173"

    send(view.pid, {:pty_data, "pane-1", "listening at http://localhost:5174\n"})
    refute has_element?(view, "#preview-candidate-5174")

    broadcast_preview_pane(view, "%2", "http://localhost:5174")
    refute has_element?(view, "#preview-candidate-5174")

    preview_panes = socket_assigns(view, :preview_panes)
    assert preview_panes["%2"][:display_url] == "http://localhost:5174"
    assert preview_panes["%1"][:display_url] == "http://localhost:5173"

    send(
      view.pid,
      {:pane_event,
       %{
         reason: :removed,
         type: :preview,
         pane_id: "%2",
         workspace_id: "ws-1",
         tmux_session: nil,
         payload: %{}
       }}
    )

    _html = render(view)
    preview_panes = socket_assigns(view, :preview_panes)
    refute Map.has_key?(preview_panes, "%2")
    assert preview_panes["%1"][:display_url] == "http://localhost:5173"
  end

  test "registered workspace preview panes rehydrate when viewing the same workspace", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-preview-rehydrate")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux = Application.get_env(:casein, :tmux_adapter)
    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, TmuxCtl.Test.FakeAdapter)

    tmux_session = "casein_alpha_u-dev"
    window = tmux_window(System.system_time(:second))
    pane = tmux_pane_with_id("%1", path: workspace_path)
    sync_fake_tmux_topology_state(tmux_session, window, [pane])

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    on_exit(fn ->
      Casein.PreviewPanes.clear()
      TmuxCtl.Test.FakeState.delete(:fake_tmux_windows)
      TmuxCtl.Test.FakeState.delete(:fake_tmux_panes)
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux)
    end)

    {:ok, _record} =
      Casein.Workspaces.State.sync(%Casein.Workspace{
        id: "ws-1",
        name: "alpha",
        user: "dev",
        status: :running,
        path: workspace_path,
        metadata: %{raw: %{"user" => "dev"}}
      })

    url = "https://casein.example.test/assets/whitehouse-preview.html"

    assert {:ok, registration} =
             Casein.PreviewPanes.register(%{
               "pane_id" => "%1",
               "url" => url,
               "workspace_id" => "ws-1",
               "cwd" => workspace_path,
               "tmux_session" => tmux_session
             })

    assert registration.workspace_id == "ws-1"
    assert [%{pane_id: "%1"}] = Casein.PreviewPanes.list_for_workspace_exact("ws-1")

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    assert socket_assigns(view, :preview_panes)["%1"][:display_url] == url

    push_tmux_topology!(view, ["%1"])
    assert_preview_pane_overlay(view, "%1", url)

    live_url = "https://casein.example.test/assets/live-folder-preview.html"
    live_pane = tmux_pane_with_id("%2", path: workspace_path, active: false, index: 1)
    sync_fake_tmux_topology_state(tmux_session, window, [pane, live_pane])

    assert {:ok, live_registration} =
             Casein.PreviewPanes.register(%{
               "pane_id" => "%2",
               "url" => live_url,
               "cwd" => workspace_path,
               "tmux_session" => tmux_session
             })

    assert Casein.Workspaces.Aliases.linked?(
             live_registration.workspace_id,
             registration.workspace_id
           )

    _html = render(view)
    assert socket_assigns(view, :preview_panes)["%2"][:display_url] == live_url
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      ref = Process.monitor(view.pid)
      Process.exit(view.pid, :shutdown)
      assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}
      assert_receive {:EXIT, _pid, :shutdown}
    after
      Process.flag(:trap_exit, trap_exit?)
    end
  end

  test "opening a preview opens a control session and control events record audited actions", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-preview-control")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    push_tmux_topology!(view, ["%1"])
    broadcast_preview_pane(view, "%1", "http://localhost:5173")
    assert_preview_pane_overlay(view, "%1", "http://localhost:5173")
  end

  test "preview pane overlay appears on registration broadcast", %{conn: conn} do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-preview-overlay")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_mode = Application.get_env(:casein, :default_workspace_mode)
    prev_tmux = Application.get_env(:casein, :tmux_adapter)
    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :default_workspace_mode, :manual)
    Application.put_env(:casein, :tmux_adapter, TmuxCtl.Test.FakeAdapter)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:default_workspace_mode, prev_mode)
      restore(:tmux_adapter, prev_tmux)
      TmuxCtl.Test.FakeState.delete(:fake_tmux_windows)
      TmuxCtl.Test.FakeState.delete(:fake_tmux_panes)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
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
      {Casein.Terminals.TmuxTopology,
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
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-preview-terminal-anchor")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_mode = Application.get_env(:casein, :default_workspace_mode)
    prev_tmux = Application.get_env(:casein, :tmux_adapter)
    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :default_workspace_mode, :manual)
    Application.put_env(:casein, :tmux_adapter, TmuxCtl.Test.FakeAdapter)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:default_workspace_mode, prev_mode)
      restore(:tmux_adapter, prev_tmux)
      TmuxCtl.Test.FakeState.delete(:fake_tmux_windows)
      TmuxCtl.Test.FakeState.delete(:fake_tmux_panes)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
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
      {Casein.Terminals.TmuxTopology,
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

    assert has_element?(
             view,
             "#tmux-pane-layout-ws-1 > #terminal-surface-ws-1[data-terminal-surface='true'][data-pane-id='%1'][phx-hook='TerminalSurface']"
           )

    assert has_element?(view, "#terminal-surface-mount-ws-1[phx-update='ignore']")

    refute has_element?(view, "#tmux-pane--1 [data-terminal-surface='true']")
    refute has_element?(view, "#tmux-pane--2 [data-terminal-surface='true']")

    surface_html = view |> element("#terminal-surface-ws-1") |> render()
    pane_html = view |> element("#tmux-pane--1") |> render()
    # The Ghostty surface spans the full tmux layout: tmux composites all panes
    # into one screen, so clipping the surface to the operator pane would crop
    # away every other pane's region (the split-pane "black tiles" regression).
    assert surface_html =~ "inset-0"
    refute surface_html =~ "left: 0.0%;"
    # Pane tiles remain positioned overlays for click/resize/highlight.
    assert pane_html =~ "left: 0.0%;"
    assert pane_html =~ "width: 66.6667%;"

    panes =
      [
        tmux_pane_with_id("%1", active: false, left: 0, index: 0),
        tmux_pane_with_id("%2", active: true, left: 60, index: 1)
      ]

    window = Map.put(tmux_window(0), :pane_list, panes)

    send(
      view.pid,
      {Casein.Terminals.TmuxTopology,
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

    assert has_element?(
             view,
             "#tmux-pane-layout-ws-1 > #terminal-surface-ws-1[data-terminal-surface='true'][data-pane-id='%1']"
           )

    refute has_element?(view, "#tmux-pane--1 [data-terminal-surface='true']")
    refute has_element?(view, "#tmux-pane--2 [data-terminal-surface='true']")
    assert has_element?(view, "#tmux-pane--2[data-pane-active='true']")
    assert socket_assigns(view, :terminal_surface_pane_id) == "%1"
  end

  test "a generic :pane_event preview registration assigns preview pane overlay state", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-preview-opened-msg")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)
    _ = Casein.PreviewControl.Registry.clear()

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      _ = Casein.PreviewControl.Registry.clear()
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    url = "http://localhost:5173/"
    broadcast_preview_pane(view, "%1", url)

    assert socket_assigns(view, :preview_panes)["%1"][:display_url] == url

    broadcast_preview_pane(view, "%2", "http://localhost:5174/", "other-workspace")

    refute Map.has_key?(socket_assigns(view, :preview_panes), "%2")
  end

  defp socket_assigns(view, key) do
    :sys.get_state(view.pid).socket.assigns[key]
  end

  test "browser control broadcasts push reload events to workspace viewers", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-browser-control")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    assert {:ok, %{request_id: iframe_request_id}} =
             Casein.Agents.PreviewTools.BrowserControl.reload_preview_iframe(%{id: "ws-1"},
               actor_id: "agent-1"
             )

    assert_push_event(view, "casein:reload_preview_iframes", %{
      "action" => "reload_preview_iframe",
      "actor_id" => "agent-1",
      "request_id" => ^iframe_request_id,
      "workspace_id" => "ws-1"
    })

    assert {:ok, %{request_id: page_request_id}} =
             Casein.Agents.PreviewTools.BrowserControl.reload_page(%{id: "ws-1"},
               actor_id: "agent-1"
             )

    assert_push_event(view, "casein:reload_page", %{
      "action" => "reload_page",
      "actor_id" => "agent-1",
      "request_id" => ^page_request_id,
      "workspace_id" => "ws-1"
    })
  end

  test "browser control focus request switches the workspace view to the preview pane", %{
    conn: conn
  } do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-browser-focus-preview")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux = Application.get_env(:casein, :tmux_adapter)
    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, TmuxCtl.Test.FakeAdapter)

    on_exit(fn ->
      TmuxCtl.Test.FakeState.delete(:fake_tmux_windows)
      TmuxCtl.Test.FakeState.delete(:fake_tmux_panes)
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:tmux_adapter, prev_tmux)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)

    tmux_session = socket_assigns(view, :tmux_session)
    operator = tmux_pane_with_id("%1", path: workspace_path, active: true, index: 0)
    preview = tmux_pane_with_id("%2", path: workspace_path, active: false, left: 60, index: 1)
    window = Map.put(tmux_window(0), :pane_list, [operator, preview])
    sync_fake_tmux_topology_state(tmux_session, window, [operator, preview])

    send(
      view.pid,
      {Casein.Terminals.TmuxTopology,
       {:updated,
        %{
          session: tmux_session,
          windows: [window],
          panes: [operator, preview],
          active_window_id: "@0",
          active_pane_id: "%1",
          version: 1,
          structure_version: 1
        }}}
    )

    broadcast_preview_pane(view, "%2", "http://localhost:5173")

    assert {:ok, %{request_id: request_id}} =
             Casein.Agents.PreviewTools.BrowserControl.focus_preview_pane(
               %{id: "ws-1"},
               tmux_session,
               "%2",
               actor_id: "agent-1"
             )

    render(view)

    assert socket_assigns(view, :entered_preview_pane_id) == "%2"
    assert socket_assigns(view, :ui_highlight_pane_id) == "%2"

    # Focus is a UI highlight only — reloading the iframe here blanks the live
    # preview on every agent focus event (the "preview flashes" bug).
    refute_push_event(view, "casein:reload_preview_iframes", %{
      "pane_id" => "%2",
      "reason" => "agent_activity:focus"
    })

    assert is_binary(request_id)
  end

  test "file tree new-item form does not use native autofocus", %{conn: conn} do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-tree-autofocus")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    render_click(view, "switch_tab", %{"tab" => "files"})
    render_click(view, "tree:new_form", %{"kind" => "file"})

    assert has_element?(view, "#tree-new-name-input[name='name']")
    refute has_element?(view, "#tree-new-name-input[autofocus]")
  end

  test "artifacts tab lists workspace artifact projects", %{conn: conn} do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-artifacts")
    workspace_path = Path.join(workspace_root, "ws-1")
    artifact_root = Path.join(workspace_root, "artifacts")
    File.mkdir_p!(workspace_path)
    init_git_repo!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_artifact_root = Application.get_env(:casein, :artifact_projects_root)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :artifact_projects_root, artifact_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
      restore(:artifact_projects_root, prev_artifact_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    assert {:ok, project} =
             ArtifactProjects.create("ws-1", %{
               name: "Cockpit Artifact",
               prompt: "Show it in the workspace panel"
             })

    html = render_click(view, "switch_tab", %{"tab" => "artifacts"})

    assert html =~ "artifact-gallery-panel"
    assert html =~ "Cockpit Artifact"
    assert html =~ "Show it in the workspace panel"
    assert html =~ project.preview_url
    assert html =~ "artifact:inspect"
    assert html =~ "artifact:serve"
    assert html =~ "artifact:open"

    html = render_click(view, "artifact:inspect", %{"artifact-id" => project.id})

    assert html =~ "artifact-detail-#{project.id}"
    assert html =~ "artifact-embedded-preview-unavailable"
  end

  test "allowed preview URLs open in an iframe pane", %{conn: conn} do
    workspace_root = Path.join(System.tmp_dir!(), "casein-workspace-preview-untrusted")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    push_tmux_topology!(view, ["%1"])
    broadcast_preview_pane(view, "%1", "http://localhost:4000")

    assert has_element?(view, "iframe[data-src='http://localhost:4000']")
  end

  test "agent write unlock grant and revoke round-trip through the run tab", %{conn: conn} do
    workspace_root = Path.join(System.tmp_dir!(), "casein-agent-write-unlock")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)
    {:ok, _} = Casein.Workspaces.State.set_mode("ws-1", :manual)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    await_mount_hydration(view)
    render_click(view, "switch_tab", %{"tab" => "run"})

    assert Casein.Workspaces.agent_write_unlock_for("ws-1") == :inactive

    html = render_submit(view, "workspace:grant_agent_write_unlock", %{"minutes" => "30"})
    assert html =~ "Agent write unlocked for 30 min."
    assert has_element?(view, "#agent-write-unlock-revoke")

    assert {:active, _until, _by} = Casein.Workspaces.agent_write_unlock_for("ws-1")

    html = render_click(view, "workspace:revoke_agent_write_unlock", %{})
    assert html =~ "Revoked."
    refute has_element?(view, "#agent-write-unlock-revoke")
    assert Casein.Workspaces.agent_write_unlock_for("ws-1") == :inactive
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
    sync_live(view)
  end

  defp sync_live(view) do
    _ = :sys.get_state(view.pid)
    view
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # Preview lifecycle reaches the LiveView through the generic
  # Casein.Panes.Events channel since the preview runtime cutover.
  defp broadcast_preview_pane(view, pane_id, url, workspace_id \\ "ws-1") do
    send(
      view.pid,
      {:pane_event,
       %{
         reason: :registered,
         type: :preview,
         pane_id: pane_id,
         workspace_id: workspace_id,
         tmux_session: nil,
         payload: %{
           workspace_id: workspace_id,
           url: url,
           display_url: url,
           preview_id: 1,
           control_session_id: 1,
           viewport: nil
         }
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
    sync_fake_tmux_topology_state(session, window, panes)

    send(
      view.pid,
      {Casein.Terminals.TmuxTopology,
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

  defp sync_fake_tmux_topology_state(session, window, panes) do
    case Application.get_env(:casein, :tmux_adapter) do
      adapter when adapter in [TmuxCtl.Test.FakeAdapter, Casein.Test.FakeTmuxAdapter] ->
        TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{session => [window]})
        TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{session => panes})

      _ ->
        :ok
    end
  end

  defp assert_preview_pane_overlay(view, pane_id, url) do
    dom_id = String.replace(pane_id, ~r/[^a-zA-Z0-9_-]/, "-")

    assert has_element?(
             view,
             "#preview-pane-#{dom_id} iframe[data-preview-iframe][data-src='#{url}']"
           )
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
      unseen_changes: false,
      zoomed?: false
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

  defp workspace_payload(
         conn,
         workspace_path,
         workspace_name \\ "alpha",
         status \\ "running",
         user \\ "dev"
       ) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "id" => "ws-1",
        "name" => workspace_name,
        "user" => user,
        "status" => status,
        "type" => "v3",
        "branch" => "main",
        "path" => workspace_path
      })
    )
  end

  defp init_git_repo!(path) do
    File.write!(Path.join(path, "README.md"), "# Workspace\n")
    git!(path, ["init", "--initial-branch=main"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Casein Test"])
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "init"])
  end

  defp git!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  @fake_state_keys ~w(fake_tmux_windows fake_tmux_panes fake_tmux_next_window fake_tmux_scrollback fake_tmux_test_pid)a

  defp restore(k, v) when k in @fake_state_keys, do: TmuxCtl.Test.FakeState.restore(k, v)
  defp restore(k, nil), do: Application.delete_env(:casein, k)
  defp restore(k, v), do: Application.put_env(:casein, k, v)

  defp kill_tmux_sessions_with_prefix(prefix) when is_binary(prefix) do
    with executable when is_binary(executable) <- System.find_executable("tmux"),
         {sessions, 0} <-
           System.cmd(
             executable,
             Casein.Terminals.TmuxServer.args() ++ ["list-sessions", "-F", "\#{session_name}"],
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
    _ =
      System.cmd("tmux", Casein.Terminals.TmuxServer.args() ++ ["kill-session", "-t", session],
        stderr_to_stdout: true
      )

    :ok
  end

  defp kill_tmux_session(_), do: :ok
end
