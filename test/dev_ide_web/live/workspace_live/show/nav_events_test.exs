defmodule DevIdeWeb.WorkspaceLive.Show.NavEventsTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.WorkspaceLive.Show.NavEvents

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            tab: "terminal",
            mobile_nav_open: false,
            mobile_nav_view: "sessions",
            mobile_nav_focus: "sessions",
            session_tabs: [],
            terminal_sid: nil,
            # Opening the sheet now builds the sessions tree (for the "Other
            # workspaces" section), so the fixture carries the same sidebar
            # assigns a mounted workspace socket has.
            workspace: %{id: "ws-test", name: "Test WS"},
            workspace_summaries: [],
            sessions_sidebar_sort: :recency,
            sidebar_expanded_workspaces: MapSet.new(),
            sidebar_expanded_dirs: MapSet.new(),
            sidebar_ws_sessions: %{},
            current_user: nil
          },
          assigns
        )
    }
  end

  describe "mobile_nav events" do
    test "mobile_nav:toggle flips mobile_nav_open" do
      {:noreply, socket} = NavEvents.handle_event("mobile_nav:toggle", %{}, socket())

      assert socket.assigns.mobile_nav_open
      assert socket.assigns.mobile_nav_view == "sessions"
    end

    test "mobile_nav:close clears mobile_nav_open" do
      {:noreply, socket} =
        NavEvents.handle_event("mobile_nav:close", %{}, socket(%{mobile_nav_open: true}))

      refute socket.assigns.mobile_nav_open
    end

    test "mobile_nav:open sets focus and view" do
      {:noreply, socket} =
        NavEvents.handle_event("mobile_nav:open", %{"focus" => "sessions"}, socket())

      assert socket.assigns.mobile_nav_open
      assert socket.assigns.mobile_nav_focus == "sessions"
      assert socket.assigns.mobile_nav_view == "sessions"
    end
  end

  describe "refresh" do
    test "is a no-op" do
      sock = socket()
      assert {:noreply, ^sock} = NavEvents.handle_event("refresh", %{}, sock)
    end
  end
end
