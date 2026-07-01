defmodule DevIdeWeb.LanFriendlyPathsLiveTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Workspaces.Aliases
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    env_keys = [
      :default_workspace,
      :default_workspace_mode,
      :home_workspace_path,
      :lan_direct_mode,
      :lan_friendly_paths,
      :lan_mode,
      :lan_path_root,
      :raw_terminal_everywhere,
      :tmux_adapter,
      :workspace_modes,
      :workspace_source,
      :workspaces_root,
      :workspaces_roots
    ]

    previous_env = Map.new(env_keys, &{&1, Application.get_env(:dev_ide, &1)})
    previous_fake_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    previous_fake_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    root =
      Path.join(
        System.tmp_dir!(),
        "devide-lan-friendly-live-#{System.unique_integer([:positive])}"
      )

    workspaces_root = Path.join(root, ".devide-workspaces")
    aws = Path.join(root, "aws")

    File.mkdir_p!(workspaces_root)
    File.mkdir_p!(aws)

    MemoryAdapter.clear()
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{})
    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{})

    Application.put_env(:dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local)
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    Application.put_env(:dev_ide, :workspaces_root, workspaces_root)
    Application.put_env(:dev_ide, :workspaces_roots, [])
    Application.put_env(:dev_ide, :home_workspace_path, root)
    Application.put_env(:dev_ide, :lan_path_root, root)
    Application.put_env(:dev_ide, :lan_mode, true)
    Application.put_env(:dev_ide, :lan_direct_mode, true)
    Application.put_env(:dev_ide, :lan_friendly_paths, true)
    Application.put_env(:dev_ide, :default_workspace, "home")
    Application.put_env(:dev_ide, :default_workspace_mode, :review)
    Application.put_env(:dev_ide, :workspace_modes, %{})
    Application.put_env(:dev_ide, :raw_terminal_everywhere, false)

    on_exit(fn ->
      MemoryAdapter.clear()
      TmuxCtl.Test.FakeState.restore(:fake_tmux_windows, previous_fake_windows)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_panes, previous_fake_panes)

      Enum.each(previous_env, fn {key, value} -> restore(key, value) end)
      File.rm_rf(root)
    end)

    %{root: root, aws: aws}
  end

  test "root URL mounts the configured home workspace", %{conn: conn, root: root} do
    {:ok, view, _html} = live(conn, "/")

    workspace = socket_assign(view, :workspace)

    assert workspace.id == "home"
    assert workspace.path == root
    assert socket_assign(view, :lan_friendly_path) == "/"
  end

  test "top-level URL path mounts the matching folder workspace", %{conn: conn, aws: aws} do
    {:ok, view, _html} = live(conn, "/aws")

    workspace = socket_assign(view, :workspace)

    assert workspace.id == Aliases.folder_id_for_path(aws)
    assert workspace.path == aws
    assert socket_assign(view, :lan_friendly_path) == "/aws"
  end

  test "reserved prefixes continue to route to their explicit DevIDE surfaces", %{conn: conn} do
    conn = get(conn, "/api/workspaces")
    assert conn.status in [401, 503]
  end

  defp socket_assign(view, key) do
    :sys.get_state(view.pid).socket.assigns[key]
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
