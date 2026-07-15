defmodule DevIdeWeb.WorkspaceLive.Show.FilePaneEventsTest do
  use DevIDE.DataCase, async: false

  # Unit coverage for the generic "pane:input" dispatch of FilePaneEvents:
  # authorization (unknown pane / other-workspace pane), the Policy.can_edit_file?
  # gate on save, the optimistic-concurrency conflict passthrough, and the
  # hook-mount hydrate reply. The tree:open_in_pane flow and the feature-pane
  # focus model run through the full LiveView in
  # test/dev_ide_web/live/workspace_live/file_pane_ui_test.exs.

  alias DevIDE.FilePanes
  alias DevIDE.Workspaces
  alias DevIdeWeb.WorkspaceLive.Show.FilePaneEvents
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  setup do
    prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)
    FilePanes.clear()
    FakeState.delete(:fake_tmux_windows)
    FakeState.delete(:fake_tmux_panes)

    on_exit(fn ->
      FilePanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      restore(:tmux_adapter, prev_tmux)
      restore(:workspaces_root, prev_root)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp seed_workspace! do
    root = Path.join(System.tmp_dir!(), "file-pane-events-#{System.unique_integer([:positive])}")
    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)
    {:ok, workspace} = DevIDE.Workspaces.attach_folder(path)
    {path, workspace}
  end

  defp seed_file_pane!(workspace, ws_root, rel, content) do
    abs = Path.join(ws_root, rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)

    {:ok, reg} =
      FilePanes.register(%{
        pane_id: "%9",
        workspace_id: workspace.id,
        tmux_session: "devide_ws_fpe",
        pane_window_id: "@1",
        open_files: [%{path: rel, line: nil}],
        active_path: rel
      })

    reg
  end

  defp socket(workspace, user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        workspace: workspace,
        current_user: user,
        workspace_mode_source: :default,
        db_isolation: %DevIDE.Workspaces.DbIsolation{}
      }
    }
  end

  defp operator_socket(workspace),
    do: socket(%{workspace | user: "dev"}, %{id: "dev", username: "dev"})

  # Empty identity — unauthenticated for Policy.can_edit_file?/1.
  defp unauthenticated_socket(workspace),
    do: socket(%{workspace | user: "alice"}, %{})

  test "pane:input save writes through the file pane when the actor is authenticated" do
    {ws_root, workspace} = seed_workspace!()
    seed_file_pane!(workspace, ws_root, "note.txt", "one")
    version = FilePanes.render_state("%9").active.version

    assert {:reply, %{ok: true}, _socket} =
             FilePaneEvents.handle_event(
               "pane:input",
               %{
                 "pane-id" => "%9",
                 "type" => "save",
                 "path" => "note.txt",
                 "content" => "two",
                 "version" => version
               },
               operator_socket(workspace)
             )

    assert File.read!(Path.join(ws_root, "note.txt")) == "two"
  end

  test "pane:input save is denied by Policy.can_edit_file? when unauthenticated" do
    {ws_root, workspace} = seed_workspace!()
    seed_file_pane!(workspace, ws_root, "note.txt", "one")
    version = FilePanes.render_state("%9").active.version

    assert {:reply, %{error: "not_allowed"}, socket} =
             FilePaneEvents.handle_event(
               "pane:input",
               %{
                 "pane-id" => "%9",
                 "type" => "save",
                 "path" => "note.txt",
                 "content" => "evil",
                 "version" => version
               },
               unauthenticated_socket(workspace)
             )

    # The denial is recorded (gate/3 stores the audited decision) and nothing
    # was written.
    refute DevIDE.Policy.Decision.allow?(socket.assigns.last_decision)
    assert File.read!(Path.join(ws_root, "note.txt")) == "one"
  end

  test "pane:input save passes the version conflict through unchanged" do
    {ws_root, workspace} = seed_workspace!()
    seed_file_pane!(workspace, ws_root, "note.txt", "one")
    version = FilePanes.render_state("%9").active.version

    # The file changes on disk after the client captured its version.
    File.write!(Path.join(ws_root, "note.txt"), "changed-behind-your-back")

    assert {:reply, %{error: "conflict"}, _socket} =
             FilePaneEvents.handle_event(
               "pane:input",
               %{
                 "pane-id" => "%9",
                 "type" => "save",
                 "path" => "note.txt",
                 "content" => "mine",
                 "version" => version
               },
               operator_socket(workspace)
             )

    assert File.read!(Path.join(ws_root, "note.txt")) == "changed-behind-your-back"
  end

  test "pane:input hydrate replies with the active tab content" do
    {ws_root, workspace} = seed_workspace!()
    seed_file_pane!(workspace, ws_root, "lib/foo.ex", "defmodule Foo do\nend\n")

    assert {:reply, %{active: active}, _socket} =
             FilePaneEvents.handle_event(
               "pane:input",
               %{"pane-id" => "%9", "type" => "hydrate"},
               operator_socket(workspace)
             )

    assert active.path == "lib/foo.ex"
    assert active.content == "defmodule Foo do\nend\n"
    assert is_binary(active.version)
    assert active.error == nil
  end

  test "pane:input refuses unknown panes and panes of other workspaces" do
    {ws_root, workspace} = seed_workspace!()
    seed_file_pane!(workspace, ws_root, "note.txt", "one")

    # Unknown pane id.
    assert {:reply, %{error: "not_found"}, _socket} =
             FilePaneEvents.handle_event(
               "pane:input",
               %{"pane-id" => "%404", "type" => "hydrate"},
               operator_socket(workspace)
             )

    # A viewer of a different workspace must not reach the pane.
    other = %DevIDE.Workspace{id: "some-other-workspace", name: "other", user: "dev"}

    assert {:reply, %{error: "not_found"}, _socket} =
             FilePaneEvents.handle_event(
               "pane:input",
               %{"pane-id" => "%9", "type" => "hydrate"},
               socket(other, %{id: "dev", username: "dev"})
             )
  end

  test "pane:input rejects unsupported input types" do
    {ws_root, workspace} = seed_workspace!()
    seed_file_pane!(workspace, ws_root, "note.txt", "one")

    assert {:reply, %{error: "unsupported_input"}, _socket} =
             FilePaneEvents.handle_event(
               "pane:input",
               %{"pane-id" => "%9", "type" => "reboot"},
               operator_socket(workspace)
             )
  end

  describe "terminal:open_file_link surface routing" do
    setup do
      prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
      prev_preflight = Application.get_env(:dev_ide, :preview_open_preflight)
      prev_persistence = Application.get_env(:dev_ide, :preview_pane_persistence_enabled)
      prev_fake_pid = FakeState.get(:fake_tmux_test_pid)

      Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)
      Application.put_env(:dev_ide, :preview_open_preflight, true)
      Application.put_env(:dev_ide, :preview_pane_persistence_enabled, false)
      FakeState.put(:fake_tmux_test_pid, self())
      DevIDE.FilePanes.LinkResolver.clear_cache()
      DevIDE.PreviewPanes.clear()
      DevIDE.FilePanes.clear()

      on_exit(fn ->
        DevIDE.FilePanes.LinkResolver.clear_cache()
        DevIDE.PreviewPanes.clear()
        DevIDE.FilePanes.clear()
        FakeState.delete(:fake_tmux_windows)
        FakeState.delete(:fake_tmux_panes)
        FakeState.delete(:fake_tmux_alive_sessions)
        FakeState.restore(:fake_tmux_test_pid, prev_fake_pid)
        restore(:tmux_adapter, prev_tmux)
        restore(:preview_open_preflight, prev_preflight)
        restore(:preview_pane_persistence_enabled, prev_persistence)
      end)

      :ok
    end

    test "default mode opens browser-viewable files in a :preview pane" do
      {ws_root, workspace, tmux_session} = seed_link_workspace!()
      File.write!(Path.join(ws_root, "shot.png"), <<137, 80, 78, 71, 13, 10, 26, 10>>)
      socket = link_socket(workspace, tmux_session)

      _ = open_file_link!(socket, "shot.png", "default")

      assert_receive {:fake_tmux_split_pane, ^tmux_session, "%1", "h", new_pane_id}
      assert %{url: url, source_url: source_url} = DevIDE.PreviewPanes.get_by_pane(new_pane_id)
      # PreviewPanes may rewrite loopback host to "localhost" for display; the
      # source URL (or the served path) still carries the static file server port.
      served = source_url || url
      assert served =~ ~r{^http://(127\.0\.0\.1|localhost):\d+/}
      assert served =~ "shot.png"
      assert FilePanes.list_for_workspace(workspace.id) == []
      assert {:ok, _pid} = DevIDE.Previews.FileServer.whereis(workspace.id)
    end

    test "default mode opens source files in a :file pane" do
      {ws_root, workspace, tmux_session} = seed_link_workspace!()
      File.mkdir_p!(Path.join(ws_root, "lib"))
      File.write!(Path.join(ws_root, "lib/foo.ex"), "defmodule Foo do\nend\n")
      socket = link_socket(workspace, tmux_session)

      _ = open_file_link!(socket, "lib/foo.ex", "default", line: 1)

      assert_receive {:fake_tmux_split_pane, ^tmux_session, "%1", "h", new_pane_id}
      assert %{active_path: "lib/foo.ex"} = FilePanes.get_by_pane(new_pane_id)
      refute DevIDE.PreviewPanes.get_by_pane(new_pane_id)
    end

    test "flip mode forces a browser-viewable file into the :file editor" do
      {ws_root, workspace, tmux_session} = seed_link_workspace!()
      File.write!(Path.join(ws_root, "report.html"), "<html><body>hi</body></html>\n")
      socket = link_socket(workspace, tmux_session)

      _ = open_file_link!(socket, "report.html", "flip")

      assert_receive {:fake_tmux_split_pane, ^tmux_session, "%1", "h", new_pane_id}
      assert %{active_path: "report.html"} = FilePanes.get_by_pane(new_pane_id)
      refute DevIDE.PreviewPanes.get_by_pane(new_pane_id)
    end

    test "flip mode forces a source file into a :preview pane" do
      {ws_root, workspace, tmux_session} = seed_link_workspace!()
      File.mkdir_p!(Path.join(ws_root, "lib"))
      File.write!(Path.join(ws_root, "lib/foo.ex"), "defmodule Foo do\nend\n")
      socket = link_socket(workspace, tmux_session)

      _ = open_file_link!(socket, "lib/foo.ex", "flip")

      assert_receive {:fake_tmux_split_pane, ^tmux_session, "%1", "h", new_pane_id}
      assert %{url: url} = DevIDE.PreviewPanes.get_by_pane(new_pane_id)
      assert url =~ "lib"
      assert url =~ "foo.ex"
      assert FilePanes.list_for_workspace(workspace.id) == []
    end

    test "forged paths outside the workspace are refused" do
      {_ws_root, workspace, tmux_session} = seed_link_workspace!()
      socket = link_socket(workspace, tmux_session)

      assert {:noreply, socket} =
               FilePaneEvents.handle_event(
                 "terminal:open_file_link",
                 %{
                   "path" => "/etc/passwd",
                   "mode" => "default",
                   "pane_id" => "%1",
                   "row" => 0,
                   "col" => 0
                 },
                 socket
               )

      refute_receive {:fake_tmux_split_pane, _, _, _, _}, 200
      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "outside the workspace"
      assert FilePanes.list_for_workspace(workspace.id) == []
    end
  end

  # Bare-socket unit tests only need the open side-effects (split + registry).
  # Topology refresh on a non-LiveView socket may still raise while building
  # session-bar assigns; the open path has already completed by then.
  defp open_file_link!(socket, path, mode, opts \\ []) do
    params = %{
      "path" => path,
      "mode" => mode,
      "pane_id" => "%1",
      "row" => 0,
      "col" => 0
    }

    params =
      case Keyword.get(opts, :line) do
        nil -> params
        line -> Map.put(params, "line", line)
      end

    try do
      FilePaneEvents.handle_event("terminal:open_file_link", params, socket)
    rescue
      e in [KeyError, ArgumentError, UndefinedFunctionError] ->
        {:topology_refresh_incomplete, e}
    end
  end

  defp seed_link_workspace! do
    {ws_root, workspace} = seed_workspace!()
    tmux_session = "devide_#{workspace.name || workspace.id}_main"
    seed_tmux!(tmux_session, ws_root)
    {ws_root, workspace, tmux_session}
  end

  defp seed_tmux!(tmux_session, ws_root) do
    FakeState.update(:fake_tmux_alive_sessions, MapSet.new(), &MapSet.put(&1, tmux_session))

    FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, tmux_session, [
        %{
          id: "@1",
          index: 0,
          name: "bash",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ])
    end)

    FakeState.update(:fake_tmux_panes, %{}, fn panes ->
      Map.put(panes, tmux_session, [
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
          current_path: ws_root,
          activity: 0,
          activity_flag: false,
          bell: false,
          unseen_changes: false
        }
      ])
    end)
  end

  defp link_socket(workspace, tmux_session) do
    panes = [
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
        current_path: workspace.path,
        activity: 0,
        activity_flag: false,
        bell: false,
        unseen_changes: false,
        pane_state: :unknown
      }
    ]

    windows = [
      %{
        id: "@1",
        index: 0,
        name: "bash",
        active: true,
        panes: 1,
        activity: 0,
        current_command: "bash",
        pane_list: panes,
        pane_state: :unknown
      }
    ]

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        workspace: workspace,
        current_user: %{id: "dev", username: "dev"},
        workspace_mode_source: :default,
        db_isolation: %DevIDE.Workspaces.DbIsolation{},
        tmux_session: tmux_session,
        tmux_windows: windows,
        tmux_panes: panes,
        # Seed the active window so refresh_tmux_topology does not treat this as
        # a window switch (which would call start_ghostty_terminal and need a
        # full LiveView socket with focused_pane_id / pane_data).
        tmux_active_window_id: "@1",
        tmux_active_pane_id: "%1",
        terminal_surface_pane_id: "%1",
        focused_pane_id: "pane-1",
        pane_data: %{},
        preview_panes: %{},
        feature_panes: %{},
        session_tabs: [],
        terminal_sid: "main",
        ui_highlight_pane_id: nil,
        unseen_quiet_window_ids: MapSet.new(),
        pane_labels: %{},
        tab: "terminal",
        host_path: Workspaces.safe_host_path(workspace),
        host_loc: Workspaces.safe_host_loc(workspace)
      }
    }
  end
end
