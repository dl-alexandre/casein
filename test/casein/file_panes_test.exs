defmodule Casein.FilePanesTest.CountingTmuxAdapter do
  @moduledoc false

  # Installed as `:tmux_adapter` while counting topology reads. Scenario
  # override: session_topology/1 bumps a counter. Everything else delegates to
  # FakeAdapter so unguarded product paths cannot mystery-red the gate
  # (#817 strategy a).

  @behaviour TmuxCtl.Adapter

  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  def session_topology(session) do
    n = FakeState.get(:topology_reads, 0)
    FakeState.put(:topology_reads, n + 1)
    FakeAdapter.session_topology(session)
  end

  defdelegate ensure_session(session, cwd), to: FakeAdapter
  defdelegate attach(session), to: FakeAdapter
  defdelegate inject(target, text), to: FakeAdapter
  defdelegate inject(target, text, opts), to: FakeAdapter
  defdelegate capture_recent(target), to: FakeAdapter
  defdelegate capture_recent(target, lines), to: FakeAdapter
  defdelegate capture_recent(target, lines, opts), to: FakeAdapter
  defdelegate send_keys(session, keys), to: FakeAdapter
  defdelegate send_keys(session, keys, opts), to: FakeAdapter
  defdelegate list_session_windows(session), to: FakeAdapter
  defdelegate list_session_panes(session), to: FakeAdapter
  defdelegate directory_inventory(), to: FakeAdapter
  defdelegate capture_scrollback(session), to: FakeAdapter
  defdelegate capture_scrollback(session, opts), to: FakeAdapter
  defdelegate new_window(session), to: FakeAdapter
  defdelegate new_window(session, opts), to: FakeAdapter
  defdelegate select_window(session, window_id), to: FakeAdapter
  defdelegate last_window(session), to: FakeAdapter
  defdelegate cycle_window(session, dir), to: FakeAdapter
  defdelegate consolidate_sessions(target_session, source_sessions), to: FakeAdapter
  defdelegate select_pane(session, pane_id), to: FakeAdapter
  defdelegate navigate_pane(session, dir), to: FakeAdapter
  defdelegate zoom_pane(session, pane_id), to: FakeAdapter
  defdelegate swap_pane(session, pane_id, direction), to: FakeAdapter
  defdelegate ensure_zoomed(session, pane_id, desired?), to: FakeAdapter
  defdelegate kill_other_panes(session, pane_id), to: FakeAdapter
  defdelegate select_layout(session, layout), to: FakeAdapter
  defdelegate next_layout(session), to: FakeAdapter
  defdelegate kill_pane(session, pane_id), to: FakeAdapter
  defdelegate split_pane(session, pane_id, direction), to: FakeAdapter
  defdelegate split_pane(session, pane_id, direction, opts), to: FakeAdapter
  defdelegate resize_pane(session, pane_id, direction), to: FakeAdapter
  defdelegate resize_pane(session, pane_id, direction, amount), to: FakeAdapter
  defdelegate resize_amount_default(), to: FakeAdapter
  defdelegate resize_amount_max(), to: FakeAdapter
  defdelegate rename_window(session, window_id, name), to: FakeAdapter
  defdelegate set_session_alias(session, name), to: FakeAdapter
  defdelegate set_pane_role(session, pane_id, role), to: FakeAdapter
  defdelegate list_windows(), to: FakeAdapter
  defdelegate list_sessions(), to: FakeAdapter
  defdelegate list_panes(), to: FakeAdapter
  defdelegate kill_window(session, window_id), to: FakeAdapter
  defdelegate kill(session), to: FakeAdapter
  defdelegate session_exists?(session), to: FakeAdapter
  defdelegate session_exists?(session, opts), to: FakeAdapter
  defdelegate session_alive?(session), to: FakeAdapter
  defdelegate apply_defaults(session), to: FakeAdapter
  defdelegate set_environment(session, key, value), to: FakeAdapter
  defdelegate set_environments(session, env), to: FakeAdapter
  defdelegate send_command(session, command), to: FakeAdapter
  defdelegate send_command(session, command, opts), to: FakeAdapter
  defdelegate paste_text(session, text), to: FakeAdapter
  defdelegate paste_text(session, text, opts), to: FakeAdapter
  defdelegate resize_window(session, cols, rows), to: FakeAdapter
  defdelegate refresh_client(session), to: FakeAdapter
  defdelegate tail_lines(output, n), to: FakeAdapter
  defdelegate server_version(), to: FakeAdapter
end

defmodule Casein.FilePanesTest do
  use Casein.DataCase, async: false

  alias Casein.FilePanes
  alias Casein.FilePanes.FilePaneRegistration
  alias Casein.FilePanesTest.CountingTmuxAdapter
  alias Casein.Panes
  alias Casein.Panes.Events, as: PaneEvents
  alias Casein.Repo
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  setup do
    prev_tmux = Application.get_env(:casein, :tmux_adapter)
    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :tmux_adapter, FakeAdapter)
    FilePanes.clear()
    FakeState.delete(:fake_tmux_windows)
    FakeState.delete(:fake_tmux_panes)
    FakeState.delete(:topology_reads)

    on_exit(fn ->
      FilePanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      FakeState.delete(:topology_reads)
      restore(:tmux_adapter, prev_tmux)
      restore(:workspaces_root, prev_root)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

  defp seed_workspace! do
    root = Casein.TmpWorkspace.root!("file-panes")
    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:casein, :workspaces_root, root)
    {:ok, workspace} = Casein.Workspaces.attach_folder(path)
    {path, workspace}
  end

  defp seed_session!(session, pane_id) do
    FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: pane_id,
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: "/tmp"
        }
      ]
    })
  end

  defp write_file!(root, rel, content) do
    abs = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)
  end

  test "open_file_in_pane splits a pane, registers, and broadcasts" do
    {root, workspace} = seed_workspace!()
    session = "casein_ws_files"
    seed_session!(session, "%1")
    write_file!(root, "lib/foo.ex", "defmodule Foo do\nend\n")
    PaneEvents.subscribe(workspace.id)

    assert {:ok, %{pane_id: pane_id, reused: false, registration: reg}} =
             FilePanes.open_file_in_pane(workspace, "lib/foo.ex",
               line: 2,
               tmux_session: session,
               anchor_pane_id: "%1"
             )

    assert is_binary(pane_id) and pane_id != "%1"
    assert reg.active_path == "lib/foo.ex"
    assert [%{path: "lib/foo.ex", line: 2}] = reg.open_files
    assert_receive {:pane_event, %{reason: :registered, type: :file, pane_id: ^pane_id}}

    # Persisted for reconnect (persistence is deferred; await the write worker).
    FilePanes.flush()
    assert Repo.get_by(FilePaneRegistration, pane_id: pane_id, status: :open)
  end

  test "second open reuses the window's file pane and adds a tab" do
    {root, workspace} = seed_workspace!()
    session = "casein_ws_files2"
    seed_session!(session, "%1")
    write_file!(root, "a.ex", "a")
    write_file!(root, "b.ex", "b")

    assert {:ok, %{pane_id: pane_id, reused: false}} =
             FilePanes.open_file_in_pane(workspace, "a.ex",
               tmux_session: session,
               anchor_pane_id: "%1"
             )

    assert {:ok, %{pane_id: ^pane_id, reused: true, registration: reg}} =
             FilePanes.open_file_in_pane(workspace, "b.ex",
               tmux_session: session,
               anchor_pane_id: "%1"
             )

    assert Enum.map(reg.open_files, & &1.path) == ["a.ex", "b.ex"]
    assert reg.active_path == "b.ex"
  end

  test "render payload reads the active file fresh; facade snapshot includes it" do
    {root, workspace} = seed_workspace!()
    session = "casein_ws_files3"
    seed_session!(session, "%1")
    write_file!(root, "readme.md", "hello")

    {:ok, %{pane_id: pane_id}} =
      FilePanes.open_file_in_pane(workspace, "readme.md",
        tmux_session: session,
        anchor_pane_id: "%1"
      )

    payload = FilePanes.render_state(pane_id)
    assert payload.active.content == "hello"
    assert is_binary(payload.active.version)
    assert [%{path: "readme.md", title: "readme.md"}] = payload.tabs

    snapshot = Panes.snapshot(workspace.id)
    assert %{^pane_id => %{type: :file}} = snapshot
    assert {:file, %{active: %{content: "hello"}}} = Panes.get_by_pane(pane_id)
  end

  test "save_tab writes with optimistic concurrency" do
    {root, workspace} = seed_workspace!()
    session = "casein_ws_files4"
    seed_session!(session, "%1")
    write_file!(root, "note.txt", "one")

    {:ok, %{pane_id: pane_id}} =
      FilePanes.open_file_in_pane(workspace, "note.txt",
        tmux_session: session,
        anchor_pane_id: "%1"
      )

    version = FilePanes.render_state(pane_id).active.version

    assert {:ok, %{version: new_version}} =
             FilePanes.save_tab(pane_id, "note.txt", "two", version)

    assert File.read!(Path.join(root, "note.txt")) == "two"
    assert new_version != version

    # Stale version conflicts instead of clobbering.
    assert {:error, :conflict} = FilePanes.save_tab(pane_id, "note.txt", "three", version)
  end

  test "closing the last tab deregisters the pane" do
    {root, workspace} = seed_workspace!()
    session = "casein_ws_files5"
    seed_session!(session, "%1")
    write_file!(root, "only.ex", "x")

    {:ok, %{pane_id: pane_id}} =
      FilePanes.open_file_in_pane(workspace, "only.ex",
        tmux_session: session,
        anchor_pane_id: "%1"
      )

    assert {:ok, :closed} = FilePanes.close_tab(pane_id, "only.ex")
    assert FilePanes.get_by_pane(pane_id) == nil
  end

  test "deferred persistence survives register→deregister ordering and never resurrects" do
    {root, workspace} = seed_workspace!()
    session = "casein_ws_defer"
    seed_session!(session, "%1")
    write_file!(root, "d.ex", "x")

    {:ok, %{pane_id: pane_id}} =
      FilePanes.open_file_in_pane(workspace, "d.ex", tmux_session: session, anchor_pane_id: "%1")

    # The open row is durable once the write worker drains.
    FilePanes.flush()
    assert %{status: :open} = Repo.get_by(FilePaneRegistration, pane_id: pane_id)

    :ok = FilePanes.deregister(pane_id)

    # The close is queued after the open; draining leaves the row closed, not
    # stuck open and not deleted — proving per-pane write ordering is preserved.
    FilePanes.flush()
    assert %{status: :closed} = Repo.get_by(FilePaneRegistration, pane_id: pane_id)

    # A read that hits the DB must not rehydrate the just-removed pane, even
    # before an explicit flush (the read path drains pending closes itself).
    assert FilePanes.list_for_workspace(workspace.id) == []
    assert FilePanes.get_by_pane(pane_id) == nil
  end

  test "open_file_in_pane without anchors takes exactly one topology snapshot" do
    {root, workspace} = seed_workspace!()
    session = "casein_ws_files_topo"
    seed_session!(session, "%1")
    write_file!(root, "topo.ex", "defmodule Topo do\nend\n")

    assert {:ok, _} =
             FilePanes.register(%{
               pane_id: "%99",
               workspace_id: workspace.id,
               tmux_session: session,
               pane_window_id: "@1",
               placement: "right",
               anchor_pane_id: "%1",
               anchor_window_id: "@1",
               open_files: [%{path: "existing.ex", line: nil}],
               active_path: "existing.ex"
             })

    Application.put_env(:casein, :tmux_adapter, CountingTmuxAdapter)
    FakeState.put(:topology_reads, 0)

    assert {:ok, %{reused: true}} =
             FilePanes.open_file_in_pane(workspace, "topo.ex", tmux_session: session)

    assert FakeState.get(:topology_reads, 0) == 1

    assert {:ok, %{reused: true}} =
             FilePanes.open_file_in_pane(workspace, "topo.ex",
               tmux_session: session,
               anchor_pane_id: "%1",
               anchor_window_id: "@1"
             )

    assert FakeState.get(:topology_reads, 0) == 1
  end
end
