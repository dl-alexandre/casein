defmodule CaseinWeb.NotificationsDrawerTest do
  @moduledoc """
  Notifications drawer on both global surfaces (the root cockpit at `/`, which
  mounts the workspaceless scratch terminal, and a workspace cockpit), plus the
  legacy `/notifications` redirect. Replaces the tests of the removed
  NotificationLive.Index full-page LiveView.
  """

  use CaseinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.Notifications
  alias Casein.Workspaces.State.MemoryAdapter

  @workspace_id "ws-1"
  @workspace_name "alpha"

  defp deliver!(attrs) do
    defaults = %{
      user_id: "dev",
      workspace_id: @workspace_id,
      type: "policy_blocked",
      severity: "warning",
      title: "Blocked by policy",
      body: "not_allowlisted",
      channels: ["in_app"]
    }

    assert {:ok, notification, :created} = Notifications.deliver(Map.merge(defaults, attrs))
    notification
  end

  # `/` mounts WorkspaceLive.Show on the synthetic scratch workspace. The bell
  # moved into the ⋯ overflow menu: `notifications-open-<ws>` is the toggle and
  # `-count` holds the unread count (no ambient badge on the ⋯ trigger itself).
  @root_open "#notifications-open-__scratch__"
  @root_count "#notifications-open-__scratch__-count"

  describe "root cockpit surface (/)" do
    setup do
      stub_manager_list([])
      :ok
    end

    test "badge shows the unread count at mount; the list stays lazy", %{conn: conn} do
      deliver!(%{})

      {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, @root_count, "1")
      # No drawer and no inbox read at mount — only the count.
      refute html =~ ~s(id="notifications-drawer")
      refute html =~ "Blocked by policy"
      assert :sys.get_state(view.pid).socket.assigns.notif_loaded? == false
    end

    test "opening the drawer renders the inbox; mark read updates the badge", %{conn: conn} do
      notification = deliver!(%{})

      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element(@root_open) |> render_click()

      assert html =~ ~s(id="notifications-drawer")
      assert html =~ "Blocked by policy"
      assert html =~ "1 unread for dev"

      html = view |> element("#notification-read-#{notification.id}") |> render_click()

      assert html =~ "0 unread for dev"
      refute has_element?(view, @root_count)
    end

    test "mark-all-read clears every unread notification", %{conn: conn} do
      deliver!(%{title: "First alert"})
      deliver!(%{title: "Second alert", type: "agent_blocked"})

      {:ok, view, _html} = live(conn, ~p"/?drawer=notifications")

      assert has_element?(view, @root_count, "2")

      html = view |> element("#notifications-mark-all-read") |> render_click()

      assert html =~ "0 unread for dev"
      refute has_element?(view, @root_count)
      assert Notifications.unread_count("dev") == 0
    end

    test "live broadcast increments the badge while the drawer is closed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, @root_count)

      deliver!(%{})

      assert render(view) =~ "notifications-open-__scratch__-count"
      assert has_element?(view, @root_count, "1")
      # Closed drawer only recounts — the list still hasn't loaded.
      assert :sys.get_state(view.pid).socket.assigns.notif_loaded? == false
    end

    test "live broadcast refreshes the list while the drawer is open", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/?drawer=notifications")

      assert html =~ "No open notifications."

      deliver!(%{title: "Fresh drawer alert"})

      html = render(view)

      assert html =~ "Fresh drawer alert"
      assert has_element?(view, @root_count, "1")
    end

    test "?drawer=notifications deep link opens the drawer", %{conn: conn} do
      deliver!(%{})

      {:ok, _view, html} = live(conn, ~p"/?drawer=notifications")

      assert html =~ ~s(id="notifications-drawer")
      assert html =~ "Blocked by policy"
      assert html =~ "1 unread for dev"
    end

    test "unknown drawer values are ignored", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?drawer=bogus")

      refute html =~ ~s(id="notifications-drawer")
    end

    test "saves global channel preferences from the drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?drawer=notifications")

      html =
        view
        |> form("#notification-preferences-form", %{
          "preferences" => %{
            "types" => %{
              "policy_blocked" => %{
                "channels" => %{"in_app" => "true", "push" => "false"}
              }
            },
            "quiet_hours" => %{"enabled" => "true", "start" => "21:00", "end" => "07:00"}
          }
        })
        |> render_submit()

      assert html =~ "Notification preferences saved."

      prefs = Notifications.get_preferences("dev")
      assert get_in(prefs.settings, ["types", "policy_blocked", "channels", "push"]) == false
      assert prefs.quiet_hours["enabled"] == true
      assert prefs.quiet_hours["start"] == "21:00"
    end
  end

  describe "workspace cockpit surface" do
    setup do
      tmux_prefix = Casein.Terminals.Tmux.workspace_session_prefix(@workspace_name)

      kill_tmux_sessions_with_prefix(tmux_prefix)
      MemoryAdapter.clear()

      on_exit(fn ->
        MemoryAdapter.clear()
        kill_tmux_sessions_with_prefix(tmux_prefix)
      end)

      :ok
    end

    test "badge at mount, toggle opens the drawer with the inbox", %{conn: conn} do
      mount_env!("devide-notif-panel-cockpit")
      notification = deliver!(%{})

      {:ok, view, html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")

      assert has_element?(view, "#notifications-open-#{@workspace_id}-count", "1")
      refute html =~ ~s(id="notifications-drawer")
      assert :sys.get_state(view.pid).socket.assigns.notif_loaded? == false

      html = view |> element("#notifications-open-#{@workspace_id}") |> render_click()

      assert html =~ ~s(id="notifications-drawer")
      assert html =~ "Blocked by policy"

      html = view |> element("#notification-read-#{notification.id}") |> render_click()

      assert html =~ "0 unread for dev"
    end

    test "?drawer=notifications deep link opens the drawer on the cockpit", %{conn: conn} do
      mount_env!("devide-notif-panel-deeplink")
      deliver!(%{title: "Cockpit deep link alert"})

      {:ok, _view, html} =
        live(conn, ~p"/workspaces/#{@workspace_id}?host=local&drawer=notifications")

      assert html =~ ~s(id="notifications-drawer")
      assert html =~ "Cockpit deep link alert"
    end

    test "live broadcast increments the cockpit badge", %{conn: conn} do
      mount_env!("devide-notif-panel-live")

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")

      refute has_element?(view, "#notifications-open-#{@workspace_id}-count")

      deliver!(%{})

      render(view)
      assert has_element?(view, "#notifications-open-#{@workspace_id}-count", "1")
    end
  end

  describe "legacy /notifications redirect" do
    test "redirects to the dashboard with the drawer deep link", %{conn: conn} do
      conn = get(conn, "/notifications")

      assert redirected_to(conn) == "/?drawer=notifications"
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp stub_manager_list(payload) do
    Req.Test.stub(Casein.Integrations.Manager.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end

  # Cockpit mount environment: workspaces root on disk + manager status stub
  # (mirrors WorkspaceHistoryPanelTest).
  defp mount_env!(root_basename) do
    workspace_root = Path.join(System.tmp_dir!(), root_basename)
    workspace_path = Path.join(workspace_root, @workspace_id)
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", @workspace_id, "status"]} =
          conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => @workspace_id,
            "name" => @workspace_name,
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
  end

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
      |> Enum.each(fn session ->
        System.cmd(
          executable,
          Casein.Terminals.TmuxServer.args() ++ ["kill-session", "-t", session],
          stderr_to_stdout: true
        )
      end)
    else
      _ -> :ok
    end
  end

  describe "bell deploy severity" do
    test "a deploy failure renders a red alert dot" do
      html =
        render_component(&CaseinWeb.NotificationsDrawer.notifications_bell/1,
          id: "notifications-bell",
          unread_count: 0,
          deploy_failure: %{message: "gate failed"}
        )

      assert html =~ "hero-bell-alert"
      assert html =~ ~s(id="notifications-bell-dot")
      assert html =~ "bg-red-600"
    end

    test "an available update renders an amber (warning) dot, not red" do
      html =
        render_component(&CaseinWeb.NotificationsDrawer.notifications_bell/1,
          id: "notifications-bell",
          unread_count: 0,
          update_available: true
        )

      assert html =~ ~s(id="notifications-bell-dot")
      assert html =~ "bg-amber-500"
      refute html =~ "bg-red-600"
    end

    test "unread notifications keep the numeric badge and suppress the deploy dot" do
      html =
        render_component(&CaseinWeb.NotificationsDrawer.notifications_bell/1,
          id: "notifications-bell",
          unread_count: 2,
          update_available: true
        )

      assert html =~ ~s(id="notifications-bell-badge")
      refute html =~ ~s(id="notifications-bell-dot")
    end

    test "no signals render a plain bell with no dot" do
      html =
        render_component(&CaseinWeb.NotificationsDrawer.notifications_bell/1,
          id: "notifications-bell",
          unread_count: 0
        )

      assert html =~ "hero-bell"
      refute html =~ "hero-bell-alert"
      refute html =~ ~s(id="notifications-bell-dot")
    end
  end
end
