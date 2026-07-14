defmodule DevIdeWeb.DesktopSessionPickerTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [assign: 3]

  alias DevIDE.Workspaces.Scratch
  alias DevIdeWeb.WorkspaceLive.Show
  alias DevIdeWeb.WorkspaceLive.Show.SessionBarVM
  alias DevIdeWeb.WorkspaceLive.Show.Sidebar

  test "desktop picker opens from seeded state and closes without touching tmux" do
    socket = desktop_socket()

    assert {:noreply, opened} = Show.handle_event("sidebar:toggle_sessions", %{}, socket)
    assert opened.assigns.sessions_sidebar_open?
    assert opened.assigns.sessions_sidebar_tree != []

    assert {:noreply, closed} = Show.handle_event("sidebar:toggle_sessions", %{}, opened)
    refute closed.assigns.sessions_sidebar_open?
    assert closed.assigns.sessions_sidebar_tree == []
  end

  test "selecting the active desktop session closes the picker" do
    {:noreply, opened} = Show.handle_event("sidebar:toggle_sessions", %{}, desktop_socket())

    assert {:noreply, selected} =
             Show.handle_event(
               "attach_terminal_session",
               %{"session-id" => Scratch.id(), "kind" => "shell"},
               opened
             )

    refute selected.assigns.sessions_sidebar_open?
  end

  test "refresh rebuilds the desktop tree without tmux" do
    {:noreply, opened} = Show.handle_event("sidebar:toggle_sessions", %{}, desktop_socket())

    assert {:noreply, refreshed} =
             Show.handle_event("terminal:refresh_sessions", %{}, opened)

    assert refreshed.assigns.sessions_sidebar_open?
    assert refreshed.assigns.sessions_sidebar_tree != []
  end

  test "selecting the synthetic desktop window closes both picker rails" do
    {:noreply, opened} = Show.handle_event("sidebar:toggle_sessions", %{}, desktop_socket())

    assert {:noreply, selected} =
             Show.handle_event("tmux:select_window", %{"window-id" => "@desktop"}, opened)

    refute selected.assigns.sessions_sidebar_open?
    refute selected.assigns.window_sidebar_open?
  end

  defp desktop_socket do
    sid = Scratch.id()

    %Phoenix.LiveView.Socket{}
    |> assign(:workspace, %{id: sid, name: "Scratch"})
    |> assign(:desktop_terminal?, true)
    |> assign(:terminal_sid, sid)
    |> assign(:workspace_summaries, [])
    |> assign(:session_tabs, [SessionBarVM.scratch_tab()])
    |> assign(:tmux_window_tabs, [])
    |> then(fn socket ->
      Enum.reduce(Sidebar.initial_assigns(), socket, fn {key, value}, acc ->
        assign(acc, key, value)
      end)
    end)
  end
end
