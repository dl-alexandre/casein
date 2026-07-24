defmodule DevIdeWeb.WorkspaceLive.FilePaneUiTest do
  @moduledoc """
  End-to-end LiveView coverage for the file-pane overlay UI:

    * "tree:open_in_pane" splits a real (fake-tmux) pane off the active
      terminal pane, registers it in DevIDE.FilePanes, switches the cockpit to
      the terminal tab, renders the `#file-pane-*` overlay root with its
      server-rendered tab strip, and pushes "file-pane:loaded".
    * With no live tmux topology, "tree:open_in_pane" falls back to today's
      tree:open (files tab).
    * The feature-pane focus invariant: `tmux:select_pane` on a file pane is a
      UI-only selection — the tmux adapter's select_pane is never called, so
      Ghostty stays attached to the operator pane. Operator panes still get
      real tmux focus.
    * A `:heartbeat` pane event refreshes the registry state without focus
      churn; `:removed` drops the overlay.
  """
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.FilePanes
  alias DevIDE.Workspaces.State.MemoryAdapter

  @workspace_id "ws-file-pane"
  @file_pane_id "%2"

  setup do
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_test_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)

    workspace_root = Path.join(System.tmp_dir!(), "devide-file-pane-ui")
    workspace_path = Path.join(workspace_root, @workspace_id)
    File.rm_rf(workspace_path)
    File.mkdir_p!(Path.join(workspace_path, "lib"))
    File.write!(Path.join(workspace_path, "lib/foo.ex"), "defmodule Foo do\nend\n")

    workspace_name = "alpha-#{System.unique_integer([:positive])}"
    tmux_session = DevIDE.Terminals.Tmux.session_name(workspace_name, "u-dev")

    MemoryAdapter.clear()
    FilePanes.clear()
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    on_exit(fn ->
      File.rm_rf(workspace_root)
      MemoryAdapter.clear()
      FilePanes.clear()

      restore_app(:workspaces_root, prev_root)
      restore_app(:tmux_adapter, prev_tmux_adapter)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_windows, prev_windows)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_panes, prev_panes)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_test_pid, prev_test_pid)
    end)

    workspace_id = @workspace_id

    Req.Test.stub(DevIDE.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", ^workspace_id, "status"]} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => @workspace_id,
            "name" => workspace_name,
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

    {:ok, tmux_session: tmux_session, workspace_path: workspace_path}
  end

  defp seed_topology(tmux_session, workspace_path, pane_ids) do
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{
          id: "@1",
          index: 0,
          name: "shell",
          active: true,
          panes: length(pane_ids),
          activity: DateTime.utc_now() |> DateTime.to_unix(),
          current_command: "bash"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session =>
        pane_ids
        |> Enum.with_index()
        |> Enum.map(fn {id, index} ->
          pane(id, "@1", index: index, active: index == 0, path: workspace_path)
        end)
    })
  end

  test "tree:open_in_pane splits a file pane, switches to the terminal tab, and renders the overlay",
       %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
    seed_topology(tmux_session, workspace_path, ["%1"])

    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)
    flush_fake_tmux()

    # Start from the files tab like the tree context menu would.
    render_click(view, "switch_tab", %{"tab" => "files"})
    render_click(view, "tree:open_in_pane", %{"path" => "lib/foo.ex"})

    # The split was anchored on the operator pane %1.
    assert_receive {:fake_tmux_split_pane, ^tmux_session, "%1", "h", new_pane_id}

    # dev_ide restores tmux focus to the anchor so Ghostty keeps the operator
    # pane (the focus-restore trick).
    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%1"}

    # Let the :pane_event broadcast land, then assert cockpit state.
    render(view)
    assert socket_assigns(view, :tab) == "terminal"

    assert %{type: :file, payload: payload} =
             socket_assigns(view, :feature_panes)[new_pane_id]

    assert payload.active_path == "lib/foo.ex"

    # Registry side: registered + persisted under the new pane id.
    assert %{active_path: "lib/foo.ex"} = FilePanes.get_by_pane(new_pane_id)

    # Overlay root + server-rendered tab strip.
    assert has_element?(view, "[data-file-pane-tab][data-path='lib/foo.ex']")
    assert render(view) =~ "foo.ex"

    # The active tab content is pushed broadcast-with-id style.
    assert_push_event(view, "file-pane:loaded", %{
      pane_id: ^new_pane_id,
      path: "lib/foo.ex",
      content: "defmodule Foo do\nend\n"
    })

    # The Ghostty surface stays on the operator pane.
    assert socket_assigns(view, :terminal_surface_pane_id) == "%1"
  end

  test "tree:open_in_pane falls back to the files tab when there is no live tmux pane",
       %{conn: conn} do
    # No fake topology seeded: the workspace has no live tmux panes.
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)

    render_click(view, "tree:open_in_pane", %{"path" => "lib/foo.ex"})

    assert socket_assigns(view, :tab) == "files"
    assert %{path: "lib/foo.ex"} = socket_assigns(view, :open_file)
    assert socket_assigns(view, :feature_panes) == %{}
  end

  test "async :load_preview_state hydrates feature panes without clobbering live pane events",
       %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
    seed_topology(tmux_session, workspace_path, ["%1", @file_pane_id, "%3"])

    # Registry seed: snapshot will include this pane after :load_preview_state.
    assert {:ok, _} =
             FilePanes.register(%{
               pane_id: @file_pane_id,
               workspace_id: @workspace_id,
               tmux_session: tmux_session,
               pane_window_id: "@1",
               open_files: [%{path: "lib/foo.ex", line: nil}],
               active_path: "lib/foo.ex"
             })

    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")

    # Connected first paint must not wait on discover_surfaces / snapshot —
    # feature_panes starts empty (same as the static render).
    assert socket_assigns(view, :feature_panes) == %{}
    assert socket_assigns(view, :preview_panes) == %{}
    assert socket_assigns(view, :preview_surfaces) == []

    # Deliver a live pane event *before* async hydration settles. The merge in
    # handle_async(:load_preview_state) must keep this entry (live wins).
    live_pane_id = "%3"

    send(
      view.pid,
      {:pane_event,
       %{
         reason: :registered,
         type: :file,
         pane_id: live_pane_id,
         workspace_id: @workspace_id,
         tmux_session: tmux_session,
         payload: %{
           tabs: [%{path: "lib/foo.ex", title: "foo.ex", line: nil}],
           active_path: "lib/foo.ex",
           active: %{
             path: "lib/foo.ex",
             content: "defmodule Foo do\nend\n",
             version: "v1",
             line: nil
           },
           workspace_id: @workspace_id,
           tmux_session: tmux_session
         }
       }}
    )

    render(view)
    assert %{type: :file} = socket_assigns(view, :feature_panes)[live_pane_id]

    # Settle :load_preview_state (and the other after-mount asyncs).
    render_async(view, 5_000)

    # Snapshot hydration brought in the registry-seeded pane.
    assert %{type: :file, payload: payload} =
             socket_assigns(view, :feature_panes)[@file_pane_id]

    assert payload.active_path == "lib/foo.ex"
    # Live event delivered before async completion was not clobbered.
    assert %{type: :file} = socket_assigns(view, :feature_panes)[live_pane_id]
    # Surfaces assign is replaced by the async result (list, possibly empty).
    assert is_list(socket_assigns(view, :preview_surfaces))
  end

  test "tmux:select_pane on a file pane is UI-only — Ghostty never attaches to the holder",
       %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
    seed_topology(tmux_session, workspace_path, ["%1", @file_pane_id])

    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)

    register_file_pane(view, tmux_session)
    render(view)

    assert %{type: :file} = socket_assigns(view, :feature_panes)[@file_pane_id]
    assert socket_assigns(view, :ui_highlight_pane_id) == @file_pane_id

    # The overlay root renders over the holder pane's rectangle.
    assert has_element?(view, "#file-pane--2")
    assert has_element?(view, "[data-file-pane-tab][data-path='lib/foo.ex']")

    flush_fake_tmux()

    # Selecting the operator pane grants real tmux focus...
    render_click(view, "tmux:select_pane", %{"pane-id" => "%1"})
    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%1"}
    flush_fake_tmux()

    # ...but selecting the file pane is a UI-only selection: no tmux focus
    # change, the surface stays on the operator pane.
    render_click(view, "tmux:select_pane", %{"pane-id" => @file_pane_id})
    refute_receive {:fake_tmux_select_pane, ^tmux_session, @file_pane_id}, 200
    assert socket_assigns(view, :ui_highlight_pane_id) == @file_pane_id
    assert socket_assigns(view, :terminal_surface_pane_id) == "%1"
  end

  test "heartbeat pane events refresh state without focus churn; removed drops the overlay",
       %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
    seed_topology(tmux_session, workspace_path, ["%1", @file_pane_id])

    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)

    register_file_pane(view, tmux_session)
    render(view)

    # Move the UI selection back to the operator pane, then heartbeat.
    render_click(view, "tmux:select_pane", %{"pane-id" => "%1"})
    assert socket_assigns(view, :ui_highlight_pane_id) == "%1"
    flush_fake_tmux()

    send(view.pid, {:pane_event, pane_event(:heartbeat, tmux_session)})
    render(view)

    # State refreshed, but no re-highlight and no tmux focus calls.
    assert %{type: :file} = socket_assigns(view, :feature_panes)[@file_pane_id]
    assert socket_assigns(view, :ui_highlight_pane_id) == "%1"
    refute_receive {:fake_tmux_select_pane, _session, _pane}, 200

    # Removal drops the assign and the overlay.
    send(view.pid, {:pane_event, pane_event(:removed, tmux_session, payload: %{})})
    render(view)

    assert socket_assigns(view, :feature_panes)[@file_pane_id] == nil
    refute has_element?(view, "#file-pane--2")
  end

  describe "chromeless header strip + viewer-local dirty" do
    test "the focused file pane's buffers render in the header context strip",
         %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
      seed_topology(tmux_session, workspace_path, ["%1", @file_pane_id])

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
      render_async(view, 5_000)

      register_file_pane(view, tmux_session)
      render(view)

      # The header row (desktop, .file-pane-strip-row) carries the focused file
      # pane's tab, keyed by pane id — separate from the in-pane strip.
      assert has_element?(
               view,
               ".file-pane-strip-row [data-file-pane-strip='#{@file_pane_id}'] " <>
                 "[data-file-pane-tab][data-path='lib/foo.ex']"
             )
    end

    test "file-pane:dirty toggles a viewer-local dot without touching the registry",
         %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
      seed_topology(tmux_session, workspace_path, ["%1", @file_pane_id])

      assert {:ok, _} =
               FilePanes.register(%{
                 pane_id: @file_pane_id,
                 workspace_id: @workspace_id,
                 tmux_session: tmux_session,
                 pane_window_id: "@1",
                 open_files: [%{path: "lib/foo.ex", line: nil}],
                 active_path: "lib/foo.ex"
               })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
      render_async(view, 5_000)
      register_file_pane(view, tmux_session)
      render(view)

      dot = ".file-pane-strip-row [data-file-pane-tab][data-path='lib/foo.ex'] [data-dirty-dot]"

      # Clean: the dot is hidden.
      assert render(element(view, dot)) =~ "hidden"

      # Mark dirty: viewer-local set updated, dot revealed, registry untouched.
      render_hook(view, "file-pane:dirty", %{
        "pane-id" => @file_pane_id,
        "path" => "lib/foo.ex",
        "dirty" => true
      })

      assert MapSet.member?(
               socket_assigns(view, :file_pane_dirty),
               {@file_pane_id, "lib/foo.ex"}
             )

      refute render(element(view, dot)) =~ "hidden"
      # The persisted registration never learns about the unsaved buffer.
      assert %{active_path: "lib/foo.ex"} = FilePanes.get_by_pane(@file_pane_id)

      # Clearing removes the marker.
      render_hook(view, "file-pane:dirty", %{
        "pane-id" => @file_pane_id,
        "path" => "lib/foo.ex",
        "dirty" => false
      })

      assert socket_assigns(view, :file_pane_dirty) == MapSet.new()
      assert render(element(view, dot)) =~ "hidden"
    end

    test "file-pane:dirty for an unregistered pane is refused",
         %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
      seed_topology(tmux_session, workspace_path, ["%1", @file_pane_id])

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
      render_async(view, 5_000)

      render_hook(view, "file-pane:dirty", %{
        "pane-id" => "%999",
        "path" => "lib/foo.ex",
        "dirty" => true
      })

      assert socket_assigns(view, :file_pane_dirty) == MapSet.new()
    end

    test "focusing a non-file pane shows the placeholder instead of tabs",
         %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
      seed_topology(tmux_session, workspace_path, ["%1", @file_pane_id])

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
      render_async(view, 5_000)
      register_file_pane(view, tmux_session)

      # Move focus to the operator pane: the file pane still exists (row stays,
      # no height jump) but its tabs leave the header.
      render_click(view, "tmux:select_pane", %{"pane-id" => "%1"})
      html = render(view)

      assert has_element?(view, ".file-pane-strip-row")
      refute has_element?(view, ".file-pane-strip-row [data-file-pane-tab]")
      assert html =~ "No file pane focused"
    end

    test "removing a file pane prunes its viewer-local dirty markers",
         %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
      seed_topology(tmux_session, workspace_path, ["%1", @file_pane_id])

      assert {:ok, _} =
               FilePanes.register(%{
                 pane_id: @file_pane_id,
                 workspace_id: @workspace_id,
                 tmux_session: tmux_session,
                 pane_window_id: "@1",
                 open_files: [%{path: "lib/foo.ex", line: nil}],
                 active_path: "lib/foo.ex"
               })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
      render_async(view, 5_000)
      register_file_pane(view, tmux_session)

      render_hook(view, "file-pane:dirty", %{
        "pane-id" => @file_pane_id,
        "path" => "lib/foo.ex",
        "dirty" => true
      })

      refute socket_assigns(view, :file_pane_dirty) == MapSet.new()

      send(view.pid, {:pane_event, pane_event(:removed, tmux_session, payload: %{})})
      render(view)

      assert socket_assigns(view, :file_pane_dirty) == MapSet.new()
    end
  end

  describe "terminal:open_file_link" do
    setup do
      DevIDE.FilePanes.LinkResolver.clear_cache()
      on_exit(fn -> DevIDE.FilePanes.LinkResolver.clear_cache() end)
      :ok
    end

    test "opens a file pane anchored to the pane under the click's grid cell",
         %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
      # Two operator panes side by side: %1 at cols 0-59, %3 at cols 60-119.
      seed_topology(tmux_session, workspace_path, ["%1", "%3"])

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
      render_async(view, 5_000)
      flush_fake_tmux()

      # The client sends the frame key's pane id ("pane-1" — the LiveView pane,
      # since the shared Ghostty surface spans the whole tmux window) plus the
      # click's grid cell. The cell falls inside %3, so the split anchors there,
      # NOT on the active pane %1.
      render_click(view, "terminal:open_file_link", %{
        "path" => "lib/foo.ex",
        "line" => 12,
        "pane_id" => "pane-1",
        "row" => 5,
        "col" => 70
      })

      assert_receive {:fake_tmux_split_pane, ^tmux_session, "%3", "h", new_pane_id}
      assert_receive {:fake_tmux_select_pane, ^tmux_session, "%3"}

      render(view)
      assert socket_assigns(view, :tab) == "terminal"

      assert %{active_path: "lib/foo.ex", open_files: [%{path: "lib/foo.ex", line: 12}]} =
               FilePanes.get_by_pane(new_pane_id)
    end

    test "a forged client path outside the workspace root is refused",
         %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
      seed_topology(tmux_session, workspace_path, ["%1"])

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
      render_async(view, 5_000)
      flush_fake_tmux()

      html =
        render_click(view, "terminal:open_file_link", %{
          "path" => "/etc/passwd",
          "pane_id" => "pane-1",
          "row" => 0,
          "col" => 0
        })

      # Refused outright: no split, no files-tab fallback, an error flash.
      refute_receive {:fake_tmux_split_pane, _session, _anchor, _dir, _pane}, 200
      assert html =~ "That link points outside the workspace."
      assert socket_assigns(view, :tab) != "files"
      assert socket_assigns(view, :open_file) == nil
      assert FilePanes.list_for_workspace(@workspace_id) == []

      # Relative escapes are refused the same way.
      render_click(view, "terminal:open_file_link", %{
        "path" => "../../etc/passwd",
        "pane_id" => "pane-1",
        "row" => 0,
        "col" => 0
      })

      refute_receive {:fake_tmux_split_pane, _session, _anchor, _dir, _pane}, 200
      assert FilePanes.list_for_workspace(@workspace_id) == []
    end

    test "falls back to the files tab when no tmux pane can anchor the split",
         %{conn: conn} do
      # No topology: the path resolves, but there is nothing to split against.
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
      render_async(view, 5_000)

      render_click(view, "terminal:open_file_link", %{
        "path" => "lib/foo.ex",
        "line" => 2,
        "pane_id" => "pane-1",
        "row" => 0,
        "col" => 0
      })

      assert socket_assigns(view, :tab) == "files"
      assert %{path: "lib/foo.ex"} = socket_assigns(view, :open_file)
      assert socket_assigns(view, :feature_panes) == %{}
    end

    test "a vanished (unresolvable) file falls back to the files tab",
         %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
      seed_topology(tmux_session, workspace_path, ["%1"])

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
      render_async(view, 5_000)
      flush_fake_tmux()

      render_click(view, "terminal:open_file_link", %{
        "path" => "lib/ghost.ex",
        "pane_id" => "pane-1",
        "row" => 0,
        "col" => 0
      })

      refute_receive {:fake_tmux_split_pane, _session, _anchor, _dir, _pane}, 200
      assert socket_assigns(view, :tab) == "files"
      assert socket_assigns(view, :open_file) == nil
      assert socket_assigns(view, :file_error) != nil
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp register_file_pane(view, tmux_session) do
    send(view.pid, {:pane_event, pane_event(:registered, tmux_session)})
    render(view)
  end

  defp pane_event(reason, tmux_session, opts \\ []) do
    %{
      reason: reason,
      type: :file,
      pane_id: @file_pane_id,
      workspace_id: @workspace_id,
      tmux_session: tmux_session,
      payload:
        Keyword.get(opts, :payload, %{
          tabs: [%{path: "lib/foo.ex", title: "foo.ex", line: nil}],
          active_path: "lib/foo.ex",
          active: %{
            path: "lib/foo.ex",
            content: "defmodule Foo do\nend\n",
            version: "v1",
            line: nil
          },
          workspace_id: @workspace_id,
          tmux_session: tmux_session
        })
    }
  end

  defp pane(id, window_id, opts) do
    %{
      id: id,
      window_id: window_id,
      index: Keyword.get(opts, :index, 0),
      active: Keyword.get(opts, :active, false),
      left: Keyword.get(opts, :index, 0) * 60,
      top: 0,
      width: 60,
      height: 40,
      current_command: "bash",
      current_path: Keyword.get(opts, :path, "/tmp"),
      activity: 0,
      activity_flag: false,
      bell: false,
      unseen_changes: false
    }
  end

  defp flush_fake_tmux do
    receive do
      {:fake_tmux_select_pane, _, _} -> flush_fake_tmux()
    after
      50 -> :ok
    end
  end

  defp socket_assigns(view, key) do
    :sys.get_state(view.pid).socket.assigns[key]
  end

  defp restore_app(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_app(key, value), do: Application.put_env(:dev_ide, key, value)
end
