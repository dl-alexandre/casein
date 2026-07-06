defmodule DevIdeWeb.WorkspaceLive.Show.FilePaneEventsTest do
  use DevIde.DataCase, async: false

  # Unit coverage for the generic "pane:input" dispatch of FilePaneEvents:
  # authorization (unknown pane / other-workspace pane), the Policy.can_edit_file?
  # gate on save, the optimistic-concurrency conflict passthrough, and the
  # hook-mount hydrate reply. The tree:open_in_pane flow and the feature-pane
  # focus model run through the full LiveView in
  # test/dev_ide_web/live/workspace_live/file_pane_ui_test.exs.

  alias DevIDE.FilePanes
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

  defp viewer_socket(workspace),
    do: socket(%{workspace | user: "alice"}, %{id: "mallory", username: "mallory"})

  test "pane:input save writes through the file pane when the actor is the operator" do
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

  test "pane:input save is denied by Policy.can_edit_file? for non-operators" do
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
               viewer_socket(workspace)
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
end
