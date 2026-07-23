defmodule DevIDE.Panes.FilePaneTest do
  use DevIDE.DataCase, async: false

  alias DevIDE.FilePanes
  alias DevIDE.Panes
  alias DevIDE.Panes.FilePane
  alias DevIDE.Panes.Pane
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  setup do
    prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)
    FilePanes.clear()
    FakeState.delete(:fake_tmux_panes)

    on_exit(fn ->
      FilePanes.clear()
      FakeState.delete(:fake_tmux_panes)
      restore(:tmux_adapter, prev_tmux)
      restore(:workspaces_root, prev_root)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp seed_workspace! do
    root = DevIDE.TmpWorkspace.root!("file-pane-beh")
    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)
    {:ok, workspace} = DevIDE.Workspaces.attach_folder(path)
    File.write!(Path.join(path, "main.ex"), "defmodule Main do\nend\n")
    {path, workspace}
  end

  test "impl/1 resolves :file to FilePane" do
    assert Pane.impl(:file) == FilePane
    assert :file in Pane.types()
  end

  test "attach registers a pane bound to an already-allocated slot; serialize round-trips" do
    {path, workspace} = seed_workspace!()

    FakeState.put(:fake_tmux_panes, %{
      "s" => [%{id: "%7", window_id: "@1", index: 0, active: true}]
    })

    ctx = %{pane_id: "%7", workspace_id: workspace.id, tmux_session: "s"}
    assert {:ok, "%7"} = FilePane.attach(%{command: "main.ex"}, ctx)

    # Idempotent on reconcile re-run.
    assert {:ok, "%7"} = FilePane.attach(%{command: "main.ex"}, ctx)

    assert FilePane.serialize("%7") == %{"type" => "file", "command" => "main.ex"}

    # A second file path opens as another tab in the same pane.
    File.write!(Path.join(path, "other.ex"), "x")
    assert {:ok, "%7"} = FilePane.attach(%{command: "other.ex"}, ctx)
    assert Enum.map(FilePanes.get_by_pane("%7").open_files, & &1.path) == ["main.ex", "other.ex"]
  end

  test "attach on a missing/unreadable path degrades to an error" do
    {_path, workspace} = seed_workspace!()
    ctx = %{pane_id: "%8", workspace_id: workspace.id, tmux_session: "s"}
    assert {:error, _reason} = FilePane.attach(%{command: "does/not/exist.ex"}, ctx)
    assert FilePanes.get_by_pane("%8") == nil
  end

  test "handle_input routes save/activate/close through the registry" do
    {path, workspace} = seed_workspace!()

    FakeState.put(:fake_tmux_panes, %{
      "s" => [%{id: "%9", window_id: "@1", index: 0, active: true}]
    })

    ctx = %{pane_id: "%9", workspace_id: workspace.id, tmux_session: "s"}
    {:ok, "%9"} = FilePane.attach(%{command: "main.ex"}, ctx)

    version = FilePane.render_payload("%9").active.version

    assert :ok =
             FilePane.handle_input("%9", %{
               "type" => "save",
               "path" => "main.ex",
               "content" => "new",
               "version" => version
             })

    assert File.read!(Path.join(path, "main.ex")) == "new"

    assert {:error, :unsupported_file_input} = FilePane.handle_input("%9", %{"type" => "bogus"})
  end

  test "facade snapshot excludes :terminal (no render_payload)" do
    refute :terminal in Panes.feature_types()
    assert :file in Panes.feature_types()
    assert :preview in Panes.feature_types()
  end

  test "render_payload for an unknown pane is empty (ownership convention)" do
    assert FilePane.render_payload("%404") == %{}
    assert Panes.get_by_pane("%404") == nil
  end
end
