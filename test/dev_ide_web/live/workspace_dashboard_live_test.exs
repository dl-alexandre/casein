defmodule DevIdeWeb.WorkspaceDashboardLiveTest do
  @moduledoc """
  Dashboard at `/` (path-first navigation Stage 3): directory browser over the
  path root plus the workspace table absorbed from the deleted picker.
  """

  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()

    on_exit(fn -> MemoryAdapter.clear() end)

    :ok
  end

  describe "workspace table (absorbed picker)" do
    test "lists workspaces from a fake manager", %{conn: conn} do
      stub_manager_list([
        %{
          "id" => "abc",
          "name" => "alpha",
          "user" => "alice",
          "status" => "running",
          "type" => "v3",
          "branch" => "main"
        }
      ])

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "alpha"
      assert html =~ "running"
      assert html =~ ~p"/workspaces/abc/previous-sessions"
      assert has_element?(view, "a[href='/workspaces/abc']", "alpha")
    end

    test "shows path context, session deep links, and agent badges", %{conn: conn} do
      prev_adapter = Application.get_env(:dev_ide, :tmux_adapter)
      prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
      prev_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
      workspace_id = "ctx-#{System.unique_integer([:positive])}"
      workspace_name = "context-ws-#{System.unique_integer([:positive])}"
      tmux_session = "devide_#{workspace_name}_u-alice"

      Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        tmux_session => [
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

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        tmux_session => [
          %{
            id: "%1",
            window_id: "@1",
            index: 0,
            active: true,
            current_command: "codex",
            current_path: "/data/workspaces/alice/#{workspace_name}",
            role: "agent"
          }
        ]
      })

      on_exit(fn ->
        restore(:tmux_adapter, prev_adapter)
        TmuxCtl.Test.FakeState.restore(:fake_tmux_windows, prev_windows)
        TmuxCtl.Test.FakeState.restore(:fake_tmux_panes, prev_panes)
      end)

      stub_manager_list([
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

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "alice/#{workspace_name}"
      assert html =~ "feature/devide"
      assert html =~ "session=u-alice"
      assert html =~ "agent ready"
    end

    test "admin all-users dashboard does not poll full list on refresh", %{conn: conn} do
      prev_user = Application.get_env(:dev_ide, :current_user)

      Application.put_env(:dev_ide, :current_user, %{
        id: "admin",
        username: "admin",
        email: "admin@local",
        role: :admin
      })

      on_exit(fn -> restore(:current_user, prev_user) end)

      counter = :counters.new(1, [])

      Req.Test.stub(DevIDE.Integrations.Manager.Client, fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([workspace_index_payload("alpha")]))
      end)

      {:ok, view, _html} = live(conn, ~p"/")
      assert :counters.get(counter, 1) == 1
      assert has_element?(view, "button[phx-click='toggle_all']", "showing: all users")

      send(view.pid, :refresh)
      :sys.get_state(view.pid)

      assert :counters.get(counter, 1) == 1
    end

    test "non-admin dashboard still refreshes the scoped list", %{conn: conn} do
      counter = :counters.new(1, [])

      Req.Test.stub(DevIDE.Integrations.Manager.Client, fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([workspace_index_payload("alpha")]))
      end)

      {:ok, view, _html} = live(conn, ~p"/")
      assert :counters.get(counter, 1) == 1

      send(view.pid, :refresh)
      # :refresh fetches via start_async; :sys.get_state ensures the message is
      # processed (async started), render_async awaits the upstream call.
      :sys.get_state(view.pid)
      render_async(view, 5_000)

      assert :counters.get(counter, 1) == 2
    end

    test "forward-auth dashboard filters an over-broad workspace list to the owner", %{
      conn: conn
    } do
      enable_forward_auth()

      stub_manager_list([
        Map.merge(workspace_index_payload("alpha"), %{"user" => "alice"}),
        Map.merge(workspace_index_payload("beta"), %{"user" => "bob"})
      ])

      conn = put_req_header(conn, "x-auth-request-email", "alice@example.com")
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "alpha"
      refute html =~ "beta"
      refute has_element?(view, "button[phx-click='toggle_all']")
    end

    test "shows actionable error when the workspace source is unreachable", %{conn: conn} do
      DevIDE.Test.ManagerStub.transport_error(:econnrefused)
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Workspace source is not reachable" or html =~ "Transport error"
    end
  end

  describe "legacy picker URL" do
    test "GET /workspaces redirects to the dashboard", %{conn: conn} do
      conn = get(conn, ~p"/workspaces")
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "directory browser" do
    setup do
      base =
        Path.join(System.tmp_dir!(), "devide-dashboard-#{System.unique_integer([:positive])}")

      File.mkdir_p!(base)

      prev_env =
        Map.new(
          [:lan_path_root, :workspaces_root, :workspaces_roots, :lan_mode],
          &{&1, Application.get_env(:dev_ide, &1)}
        )

      Application.put_env(:dev_ide, :lan_path_root, base)
      Application.put_env(:dev_ide, :workspaces_root, base)
      Application.put_env(:dev_ide, :workspaces_roots, [])

      on_exit(fn ->
        Enum.each(prev_env, fn {key, value} -> restore(key, value) end)
        File.rm_rf(base)
      end)

      %{root: base}
    end

    test "lists root directories and browses deeper via ?dir=", %{conn: conn, root: root} do
      nested = Path.join([root, "dev", "child", "nested"])
      File.mkdir_p!(nested)

      stub_manager_list([])

      {:ok, view, html} = live(conn, ~p"/")
      assert has_element?(view, "#dashboard-dirs li[data-dir='dev']")
      assert html =~ "dev/"

      {:ok, view, html} = live(conn, "/?dir=dev")
      assert has_element?(view, "#dashboard-dirs li[data-dir='dev/child']")
      assert html =~ "child/"

      folder_id = "folder:" <> Base.url_encode64(Path.join(root, "dev/child"), padding: false)
      render_click(view, "folder:open", %{"path" => Path.join(root, "dev/child")})

      assert_redirect(view, ~p"/workspaces/#{folder_id}")
    end

    test "hidden and ignored directories are not listed", %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "visible"))
      File.mkdir_p!(Path.join(root, ".hidden"))
      File.mkdir_p!(Path.join(root, "node_modules"))

      stub_manager_list([])

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#dashboard-dirs li[data-dir='visible']")
      refute has_element?(view, "#dashboard-dirs li[data-dir='.hidden']")
      refute has_element?(view, "#dashboard-dirs li[data-dir='node_modules']")
    end

    test "?dir= rejects traversal outside the root", %{conn: conn, root: root} do
      outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)

      stub_manager_list([])

      {:ok, _view, html} = live(conn, "/?dir=../" <> Path.basename(outside))
      assert html =~ "Directory is outside the path root."
    end

    test "?dir= rejects symlink escapes", %{conn: conn, root: root} do
      outside = Path.join(Path.dirname(root), "symlinked-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(root, "link"))
      on_exit(fn -> File.rm_rf(outside) end)

      stub_manager_list([])

      {:ok, _view, html} = live(conn, "/?dir=link")
      assert html =~ "Directory link leaves the path root."
    end

    test "directories holding known workspaces render enriched rows", %{conn: conn, root: root} do
      project = Path.join(root, "proj")
      File.mkdir_p!(project)

      stub_manager_list([
        Map.merge(workspace_index_payload("proj-ws"), %{"path" => project})
      ])

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#dashboard-dirs li[data-dir='proj'] [phx-click='stop']")
      assert has_element?(view, "#dashboard-dirs li[data-dir='proj'] a", "History")
    end

    test "attach form opens an allowed folder", %{conn: conn, root: root} do
      folder = Path.join([root, "dev", "oss"])
      File.mkdir_p!(folder)

      stub_manager_list([])

      {:ok, view, _html} = live(conn, ~p"/")
      folder_id = "folder:" <> Base.url_encode64(folder, padding: false)

      view
      |> form("#attach-folder-form", %{"folder" => %{"path" => folder}})
      |> render_submit()

      assert_redirect(view, ~p"/workspaces/#{folder_id}")
    end

    test "attach form rejects folder paths outside allowed roots", %{conn: conn, root: root} do
      outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)

      stub_manager_list([])

      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("#attach-folder-form", %{"folder" => %{"path" => outside}})
        |> render_submit()

      assert html =~ "Folder path is outside the allowed roots."
    end

    test "forward-auth viewers see only their own directories", %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "alice"))
      File.mkdir_p!(Path.join(root, "bob"))

      enable_forward_auth()
      stub_manager_list([])

      conn = put_req_header(conn, "x-auth-request-email", "alice@example.com")
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#dashboard-dirs li[data-dir='alice']")
      refute has_element?(view, "#dashboard-dirs li[data-dir='bob']")
    end

    test "forward-auth viewers also see directories holding their workspaces", %{
      conn: conn,
      root: root
    } do
      File.mkdir_p!(Path.join([root, "shared", "proj"]))
      File.mkdir_p!(Path.join(root, "bob"))

      enable_forward_auth()

      stub_manager_list([
        Map.merge(workspace_index_payload("proj-ws"), %{
          "user" => "alice",
          "path" => Path.join([root, "shared", "proj"])
        })
      ])

      conn = put_req_header(conn, "x-auth-request-email", "alice@example.com")
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#dashboard-dirs li[data-dir='shared']")
      refute has_element?(view, "#dashboard-dirs li[data-dir='bob']")
    end

    test "forward-auth ?dir= into another user's directory is refused", %{
      conn: conn,
      root: root
    } do
      File.mkdir_p!(Path.join(root, "bob"))

      enable_forward_auth()
      stub_manager_list([])

      conn = put_req_header(conn, "x-auth-request-email", "alice@example.com")
      {:ok, _view, html} = live(conn, "/?dir=bob")

      assert html =~ "This directory belongs to another user."
    end

    test "forward-auth admins see all directories by default", %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "alice"))
      File.mkdir_p!(Path.join(root, "bob"))

      enable_forward_auth()
      Application.put_env(:dev_ide, :admins, ["boss@example.com"])
      stub_manager_list([])

      conn = put_req_header(conn, "x-auth-request-email", "boss@example.com")
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#dashboard-dirs li[data-dir='alice']")
      assert has_element?(view, "#dashboard-dirs li[data-dir='bob']")
    end

    test "trusted LAN sees every directory unfiltered", %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "alice"))
      File.mkdir_p!(Path.join(root, "bob"))

      Application.put_env(:dev_ide, :lan_mode, true)
      stub_manager_list([])

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#dashboard-dirs li[data-dir='alice']")
      assert has_element?(view, "#dashboard-dirs li[data-dir='bob']")
    end
  end

  describe "lan_direct mode" do
    test "the root URL redirects to the configured default workspace", %{conn: conn} do
      prev_env =
        Map.new(
          [:lan_mode, :lan_direct_mode, :default_workspace],
          &{&1, Application.get_env(:dev_ide, &1)}
        )

      Application.put_env(:dev_ide, :lan_mode, true)
      Application.put_env(:dev_ide, :lan_direct_mode, true)
      Application.put_env(:dev_ide, :default_workspace, "home")

      on_exit(fn -> Enum.each(prev_env, fn {key, value} -> restore(key, value) end) end)

      assert {:error, {:redirect, %{to: "/workspaces/home"}}} = live(conn, ~p"/")
    end
  end

  defp enable_forward_auth do
    Application.put_env(:dev_ide, :forward_auth, true)

    on_exit(fn ->
      Application.delete_env(:dev_ide, :forward_auth)
      Application.delete_env(:dev_ide, :admins)
    end)
  end

  defp stub_manager_list(payload) do
    Req.Test.stub(DevIDE.Integrations.Manager.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
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

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
