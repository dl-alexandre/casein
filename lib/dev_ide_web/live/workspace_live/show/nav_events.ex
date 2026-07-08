defmodule DevIdeWeb.WorkspaceLive.Show.NavEvents do
  # Mobile navigation and tab-switch handle_event clauses extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  # Show delegates "mobile_nav:*", "switch_tab", and "refresh" events here.
  @moduledoc false

  import Phoenix.Component

  alias DevIdeWeb.WorkspaceLive.Show

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, Show.select_tab(socket, tab)}
  end

  def handle_event("refresh", _params, socket) do
    # Older Ghostty assets sent component refreshes to the parent LiveView.
    # Keep that harmless during rolling deploys instead of crashing the socket.
    {:noreply, socket}
  end

  # The sheet is window-picker dominant: the keybar chip opens on the attached
  # session's window list (with a back arrow to the sessions list), falling
  # back to the sessions list when the attached session has no tmux windows.
  def handle_event("mobile_nav:toggle", _params, socket) do
    view = mobile_nav_resolved_view(socket, "windows")

    {:noreply,
     socket
     |> update(:mobile_nav_open, &(!&1))
     |> assign(:mobile_nav_view, view)
     |> assign(:mobile_nav_focus, view)}
  end

  # Opened by the Ctrl+B leader shortcut on touch/narrow layouts (see
  # assets/js/workspace_leader.js). `focus` lands the in-sheet keyboard cursor
  # on the active session ("sessions") or active window ("windows") and picks
  # the matching sheet view.
  def handle_event("mobile_nav:open", %{"focus" => focus}, socket)
      when focus in ~w(sessions windows) do
    {:noreply,
     socket
     |> assign(:mobile_nav_open, true)
     |> assign(:mobile_nav_view, mobile_nav_resolved_view(socket, focus))
     |> assign(:mobile_nav_focus, focus)}
  end

  # Back arrow (windows → sessions) and the hook's ← hop use this to flip the
  # open sheet between its two views without closing it.
  def handle_event("mobile_nav:set_view", %{"view" => view}, socket)
      when view in ~w(sessions windows) do
    view = mobile_nav_resolved_view(socket, view)

    {:noreply,
     socket
     |> assign(:mobile_nav_view, view)
     |> assign(:mobile_nav_focus, view)}
  end

  def handle_event("mobile_nav:close", _params, socket) do
    {:noreply, assign(socket, :mobile_nav_open, false)}
  end

  defp mobile_nav_active_tab(assigns) do
    Enum.find(assigns[:session_tabs] || [], &(&1.id == assigns[:terminal_sid]))
  end

  defp mobile_nav_resolved_view(_socket, "sessions"), do: "sessions"

  defp mobile_nav_resolved_view(socket, "windows") do
    case mobile_nav_active_tab(socket.assigns) do
      %{windows: [_ | _]} -> "windows"
      _ -> "sessions"
    end
  end
end
