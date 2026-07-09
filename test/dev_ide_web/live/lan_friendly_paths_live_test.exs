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

  test "root URL mounts the scratch cockpit", %{conn: conn, aws: _aws} do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "#workspace-header-__scratch__")
    assert has_element?(view, "#notifications-bell-__scratch__")
    refute has_element?(view, "#workspace-admin-bell-__scratch__")
  end

  test "the home workspace serves at its id URL", %{conn: conn, root: root} do
    {:ok, view, _html} = live(conn, "/workspaces/home")

    workspace = socket_assign(view, :workspace)

    assert workspace.id == "home"
    assert workspace.path == root
    assert socket_assign(view, :path_route) == nil
  end

  test "LAN-friendly home workspace remains authorized for UI events", %{
    conn: conn,
    root: root
  } do
    {:ok, view, _html} = live(conn, "/workspaces/home")

    html = render_hook(view, "terminal:toggle_chrome", %{})

    assert socket_assign(view, :workspace).path == root
    refute html =~ "You do not have access to this workspace."
  end

  test "top-level URL path mounts the matching folder workspace", %{conn: conn, aws: aws} do
    {:ok, view, _html} = live(conn, "/aws")

    workspace = socket_assign(view, :workspace)

    assert workspace.id == Aliases.folder_id_for_path(aws)
    assert workspace.path == aws
    assert socket_assign(view, :path_route) == "/aws"
  end

  describe "always-on path routing" do
    test "subdirectory URLs walk up to the repo root", %{conn: conn, aws: aws} do
      File.mkdir_p!(Path.join(aws, ".git"))
      File.mkdir_p!(Path.join(aws, "lib"))

      {:ok, view, _html} = live(conn, "/aws/lib")

      assert socket_assign(view, :workspace).path == aws
      assert socket_assign(view, :path_route) == "/aws/lib"
      assert socket_assign(view, :workspace_route) == "/aws"
    end

    test "the workspace header renders the parent-directory breadcrumb trail", %{
      conn: conn,
      root: root
    } do
      repo = Path.join([root, "team", "repo"])
      File.mkdir_p!(Path.join(repo, ".git"))

      {:ok, view, html} = live(conn, "/team/repo")

      # The breadcrumb trail surfaces the parent directory ("team"); the home
      # ← link was retired in favour of the header session-picker toggle (home
      # is reachable via the Scratch node in the summoned SESSIONS rail).
      assert has_element?(view, "nav[aria-label='Breadcrumb']")
      refute has_element?(view, "nav[aria-label='Breadcrumb'] a[href='/']")
      assert html =~ "team"
    end

    test "id URLs canonicalize onto the path route, preserving deep-link params", %{
      conn: conn,
      root: root
    } do
      alpha = Path.join(root, ".devide-workspaces/alpha")
      File.mkdir_p!(alpha)

      assert {:error, {:redirect, %{to: to}}} =
               live(conn, "/workspaces/alpha?session=s-1&zoom=1&host=local")

      assert to == "/.devide-workspaces/alpha?session=s-1&zoom=1"
    end

    test "workspaces outside the path root keep serving at the id URL", %{conn: conn} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "devide-outside-root-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)
      Application.put_env(:dev_ide, :workspaces_roots, [outside])

      alpha = Path.join(outside, "alpha")
      File.mkdir_p!(alpha)
      {:ok, ws} = DevIDE.Workspaces.attach_folder(alpha)

      {:ok, view, _html} = live(conn, "/workspaces/#{ws.id}")

      assert socket_assign(view, :workspace).path == alpha
      assert socket_assign(view, :path_route) == nil
    end
  end

  describe "deployment-mode access control" do
    defp enable_forward_auth do
      Application.put_env(:dev_ide, :forward_auth, true)

      on_exit(fn ->
        Application.delete_env(:dev_ide, :forward_auth)
        Application.delete_env(:dev_ide, :admins)
      end)
    end

    defp as_forward_auth_user(conn, email) do
      Plug.Conn.put_req_header(conn, "x-auth-request-email", email)
    end

    test "forward auth overrides LAN trust: non-owner path mounts are refused", %{conn: conn} do
      enable_forward_auth()

      # "dev" does not own the "aws" folder (owner derives from the
      # /<root>/<user>/... layout).
      conn = as_forward_auth_user(conn, "dev@local")

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/aws")
    end

    test "forward auth: the folder owner may mount its path URL", %{conn: conn, aws: aws} do
      enable_forward_auth()
      conn = as_forward_auth_user(conn, "aws@local")

      {:ok, view, _html} = live(conn, "/aws")
      assert socket_assign(view, :workspace).path == aws

      # And the event gate agrees with the mount decision.
      html = render_hook(view, "terminal:toggle_chrome", %{})
      refute html =~ "You do not have access to this workspace."
    end

    test "forward auth: admins may mount any path URL", %{conn: conn, aws: aws} do
      enable_forward_auth()
      Application.put_env(:dev_ide, :admins, ["boss@local"])
      conn = as_forward_auth_user(conn, "boss@local")

      {:ok, view, _html} = live(conn, "/aws")
      assert socket_assign(view, :workspace).path == aws
    end

    test "forward auth: id URLs stay opaque, no path canonicalization", %{
      conn: conn,
      root: root
    } do
      enable_forward_auth()
      Application.put_env(:dev_ide, :admins, ["boss@local"])
      conn = as_forward_auth_user(conn, "boss@local")

      alpha = Path.join(root, ".devide-workspaces/alpha")
      File.mkdir_p!(alpha)

      {:ok, view, _html} = live(conn, "/workspaces/alpha")

      assert socket_assign(view, :workspace).path == alpha
      assert socket_assign(view, :path_route) == nil
    end

    test "forward auth: the root URL mounts the scratch cockpit", %{conn: conn} do
      enable_forward_auth()
      conn = as_forward_auth_user(conn, "dev@local")

      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#workspace-header-__scratch__")
    end

    test "outside LAN mode path mounts also enforce viewer access", %{conn: conn} do
      Application.put_env(:dev_ide, :lan_mode, false)

      # The static dev fallback user does not own the "aws" folder.
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/aws")
    end
  end

  test "missing URL path renders an in-place LAN path error", %{conn: conn, root: root} do
    path = "/does-not-exist"
    target_path = Path.join(root, "does-not-exist")

    conn = get(conn, path)
    html = html_response(conn, 200)

    assert html =~ ~s(id="lan-path-error")
    assert html =~ "Directory not found"
    assert html =~ "directory was not found"
    assert html =~ target_path

    {:ok, view, html} = live(recycle(conn), path)

    assert html =~ ~s(id="lan-path-error")
    assert html =~ "Directory not found"

    lan_path_error = socket_assign(view, :lan_path_error)
    assert lan_path_error.reason == :not_found
    assert lan_path_error.route_path == path
    assert lan_path_error.target_path == target_path
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
