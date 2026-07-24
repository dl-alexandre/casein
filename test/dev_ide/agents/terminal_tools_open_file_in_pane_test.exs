defmodule Casein.Agents.TerminalToolsOpenFileInPaneTest do
  use Casein.DataCase, async: false

  alias Casein.Agents.TerminalTools
  alias Casein.FilePanes
  alias Casein.FilePanes.LinkResolver
  alias Casein.PreviewPanes
  alias Casein.Previews.FileServer
  alias Casein.Terminals.Tmux
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  setup do
    prev = %{
      tmux_adapter: Application.get_env(:dev_ide, :tmux_adapter),
      workspaces_root: Application.get_env(:dev_ide, :workspaces_root),
      preview_open_preflight: Application.get_env(:dev_ide, :preview_open_preflight),
      preview_pane_persistence: Application.get_env(:dev_ide, :preview_pane_persistence_enabled),
      file_pane_persistence: Application.get_env(:dev_ide, :file_pane_persistence),
      fake_tmux_test_pid: FakeState.get(:fake_tmux_test_pid)
    }

    Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)
    Application.put_env(:dev_ide, :preview_open_preflight, true)
    Application.put_env(:dev_ide, :preview_pane_persistence_enabled, false)
    Application.put_env(:dev_ide, :file_pane_persistence, false)
    FakeState.put(:fake_tmux_test_pid, self())
    FilePanes.clear()
    PreviewPanes.clear()
    LinkResolver.clear_cache()
    FakeState.delete(:fake_tmux_windows)
    FakeState.delete(:fake_tmux_panes)
    FakeState.delete(:fake_tmux_alive_sessions)

    on_exit(fn ->
      FilePanes.clear()
      PreviewPanes.clear()
      LinkResolver.clear_cache()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      FakeState.delete(:fake_tmux_alive_sessions)
      FakeState.restore(:fake_tmux_test_pid, prev.fake_tmux_test_pid)
      restore(:tmux_adapter, prev.tmux_adapter)
      restore(:workspaces_root, prev.workspaces_root)
      restore(:preview_open_preflight, prev.preview_open_preflight)
      restore(:preview_pane_persistence_enabled, prev.preview_pane_persistence)
      restore(:file_pane_persistence, prev.file_pane_persistence)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp seed_workspace! do
    root = Path.join(System.tmp_dir!(), "mcp-open-file-#{System.unique_integer([:positive])}")
    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)
    {:ok, workspace} = Casein.Workspaces.attach_folder(path)
    {path, workspace}
  end

  defp seed_session!(workspace, ws_root) do
    session = Tmux.session_name(workspace.name || workspace.id, "main")
    FakeState.update(:fake_tmux_alive_sessions, MapSet.new(), &MapSet.put(&1, session))

    FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 1}]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
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
          current_path: ws_root
        }
      ]
    })

    session
  end

  defp write_file!(root, rel, content) do
    abs = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)
  end

  test "opens a source file in a file pane at the requested line" do
    {root, workspace} = seed_workspace!()
    session = seed_session!(workspace, root)
    write_file!(root, "lib/foo.ex", "defmodule Foo do\n  def bar, do: :ok\nend\n")

    assert {:ok,
            %{
              surface: "file",
              path: "lib/foo.ex",
              line: 2,
              pane_id: pane_id,
              reused: false,
              session: ^session,
              status: "opened"
            }} =
             TerminalTools.invoke("file_open_in_pane", %{
               "workspace_id" => workspace.id,
               "session" => session,
               "path" => "lib/foo.ex",
               "line" => 2
             })

    assert is_binary(pane_id) and pane_id != "%1"

    assert %{active_path: "lib/foo.ex", open_files: [%{path: "lib/foo.ex", line: 2}]} =
             FilePanes.get_by_pane(pane_id)
  end

  test "reuses the window file pane for a second open" do
    {root, workspace} = seed_workspace!()
    session = seed_session!(workspace, root)
    write_file!(root, "a.ex", "a\n")
    write_file!(root, "b.ex", "b\n")

    assert {:ok, %{pane_id: pane_id, reused: false}} =
             TerminalTools.invoke("file_open_in_pane", %{
               "workspace_id" => workspace.id,
               "session" => session,
               "path" => "a.ex"
             })

    assert {:ok, %{pane_id: ^pane_id, reused: true, path: "b.ex", surface: "file"}} =
             TerminalTools.invoke("file_open_in_pane", %{
               "workspace_id" => workspace.id,
               "session" => session,
               "path" => "b.ex"
             })
  end

  test "rejects paths outside the workspace root" do
    {_root, workspace} = seed_workspace!()
    session = seed_session!(workspace, "/tmp")

    assert {:error, :outside_root} =
             TerminalTools.invoke("file_open_in_pane", %{
               "workspace_id" => workspace.id,
               "session" => session,
               "path" => "/etc/passwd"
             })

    assert FilePanes.list_for_workspace(workspace.id) == []
  end

  test "rejects missing files" do
    {_root, workspace} = seed_workspace!()
    session = seed_session!(workspace, "/tmp")

    assert {:error, :not_found} =
             TerminalTools.invoke("file_open_in_pane", %{
               "workspace_id" => workspace.id,
               "session" => session,
               "path" => "does/not/exist.ex"
             })
  end

  test "routes browser-viewable files to a preview pane" do
    {root, workspace} = seed_workspace!()
    session = seed_session!(workspace, root)
    write_file!(root, "shot.png", <<137, 80, 78, 71, 13, 10, 26, 10>>)

    assert {:ok,
            %{
              surface: "preview",
              path: "shot.png",
              pane_id: pane_id,
              url: url,
              status: "opened"
            }} =
             TerminalTools.invoke("file_open_in_pane", %{
               "workspace_id" => workspace.id,
               "session" => session,
               "path" => "shot.png"
             })

    assert is_binary(pane_id) and pane_id != "%1"
    assert url =~ ~r{^http://127\.0\.0\.1:\d+/shot\.png}
    assert %{url: registered_url} = PreviewPanes.get_by_pane(pane_id)
    assert registered_url =~ "shot.png"
    assert FilePanes.list_for_workspace(workspace.id) == []
    assert {:ok, _pid} = FileServer.whereis(workspace.id)
  end

  test "returns no_live_session when the workspace has no tmux session" do
    {root, workspace} = seed_workspace!()
    write_file!(root, "readme.md", "hi\n")

    assert {:error, :no_live_session} =
             TerminalTools.invoke("file_open_in_pane", %{
               "workspace_id" => workspace.id,
               "path" => "readme.md"
             })
  end

  test "rejects a missing path argument before any tmux work" do
    assert {:error, {:missing_argument, "path"}} =
             TerminalTools.invoke("file_open_in_pane", %{
               "workspace_id" => "ws-1"
             })
  end

  test "rejects binary content on the file surface" do
    {root, workspace} = seed_workspace!()
    session = seed_session!(workspace, root)
    write_file!(root, "blob.dat", <<0, 1, 2, 3, 4, 5>>)

    assert {:error, :binary} =
             TerminalTools.invoke("file_open_in_pane", %{
               "workspace_id" => workspace.id,
               "session" => session,
               "path" => "blob.dat"
             })
  end
end
