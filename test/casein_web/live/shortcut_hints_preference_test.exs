defmodule CaseinWeb.ShortcutHintsPreferenceTest do
  @moduledoc """
  The keyboard-shortcut coach preference.

  Client-read, unlike the rest of the preference map: `app.js` checks
  `data-shortcut-hints` on every header click. That means the value has to be on
  the page from the connected mount — if it waited for the drawer to lazy-load
  preferences, a reload would silently re-enable hints the operator turned off.
  """

  use CaseinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.Notifications
  alias CaseinWeb.NotificationsDrawerEvents

  setup do
    stub_manager_list([])
    :ok
  end

  defp stub_manager_list(payload) do
    Req.Test.stub(Casein.Integrations.Manager.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end

  describe "shortcut_hints_enabled?/1" do
    test "defaults to enabled — a new operator is who the hints are for" do
      assert NotificationsDrawerEvents.shortcut_hints_enabled?("nobody")
      assert NotificationsDrawerEvents.shortcut_hints_enabled?(%{settings: %{}})
      assert NotificationsDrawerEvents.shortcut_hints_enabled?(%{settings: %{"ui" => %{}}})
      assert NotificationsDrawerEvents.shortcut_hints_enabled?(nil)
    end

    test "honors a stored false, including the string form a form submits" do
      refute NotificationsDrawerEvents.shortcut_hints_enabled?(%{
               settings: %{"ui" => %{"shortcut_hints" => false}}
             })

      refute NotificationsDrawerEvents.shortcut_hints_enabled?(%{
               settings: %{"ui" => %{"shortcut_hints" => "false"}}
             })
    end
  end

  test "the connected mount publishes the preference for the client", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(data-shortcut-hints="true")

    Notifications.put_preferences("dev", %{
      settings: %{"ui" => %{"shortcut_hints" => false}}
    })

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(data-shortcut-hints="false")
  end

  test "saving preferences from the drawer flips the published value", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "notifications:toggle")

    assert has_element?(view, "#pref-shortcut-hints")

    html =
      view
      |> form("#notification-preferences-form", %{
        "preferences" => %{
          "ui" => %{"shortcut_hints" => "false"},
          "quiet_hours" => %{"enabled" => "false", "start" => "22:00", "end" => "08:00"}
        }
      })
      |> render_submit()

    assert html =~ ~s(data-shortcut-hints="false")
    refute NotificationsDrawerEvents.shortcut_hints_enabled?("dev")

    html =
      view
      |> form("#notification-preferences-form", %{
        "preferences" => %{
          "ui" => %{"shortcut_hints" => "true"},
          "quiet_hours" => %{"enabled" => "false", "start" => "22:00", "end" => "08:00"}
        }
      })
      |> render_submit()

    assert html =~ ~s(data-shortcut-hints="true")
    assert NotificationsDrawerEvents.shortcut_hints_enabled?("dev")
  end

  test "an omitted interface group reads as off", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "notifications:toggle")

    render_click(view, "notifications:save_preferences", %{
      "preferences" => %{"quiet_hours" => %{"enabled" => "false"}}
    })

    refute NotificationsDrawerEvents.shortcut_hints_enabled?("dev")
  end

  # The UI group must not wipe the per-event channel matrix that shares the row.
  test "saving the interface group preserves event channel preferences", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "notifications:toggle")

    view
    |> form("#notification-preferences-form", %{
      "preferences" => %{
        "types" => %{"needs_review" => %{"channels" => %{"push" => "false"}}},
        "ui" => %{"shortcut_hints" => "true"},
        "quiet_hours" => %{"enabled" => "false", "start" => "22:00", "end" => "08:00"}
      }
    })
    |> render_submit()

    preference = Notifications.get_preferences("dev")

    assert preference.settings["types"]["needs_review"]["channels"]["push"] == false
    assert preference.settings["ui"]["shortcut_hints"] == true
  end
end
