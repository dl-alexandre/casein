defmodule DevIdeWeb.NotificationLiveTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Notifications

  test "renders inbox rows and marks a notification read", %{conn: conn} do
    assert {:ok, notification, :created} =
             Notifications.deliver(%{
               user_id: "dev",
               workspace_id: "ws-1",
               type: "policy_blocked",
               severity: "warning",
               title: "Blocked by policy",
               body: "not_allowlisted",
               channels: ["in_app"]
             })

    assert {:ok, view, html} = live(conn, ~p"/notifications")
    assert html =~ "Blocked by policy"
    assert html =~ "1 unread"

    assert view
           |> element("#notification-read-#{notification.id}")
           |> render_click() =~ "0 unread"
  end

  test "saves global channel preferences", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/notifications")

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

    prefs = Notifications.get_preferences("dev")
    assert get_in(prefs.settings, ["types", "policy_blocked", "channels", "push"]) == false
    assert prefs.quiet_hours["enabled"] == true
    assert prefs.quiet_hours["start"] == "21:00"
  end
end
