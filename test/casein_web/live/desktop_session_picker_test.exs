defmodule CaseinWeb.DesktopSessionPickerTest.PowerShellSessionStub do
  @moduledoc false
  # Minimal stand-in registered under the real PowerShellSession name so the
  # desktop `tmux:refresh_windows` handler (restart → attach_desktop_terminal)
  # can complete in the Linux test env, where no native shell transport exists.
  # Only this test file touches that global name, so registering it here is safe.
  use GenServer

  def start_link(_opts),
    do: GenServer.start_link(__MODULE__, :ok, name: Casein.Desktop.PowerShellSession)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:restart, _cwd, _workspace}, _from, state), do: {:reply, :ok, state}
  def handle_call({:ensure_workspace, _cwd, _workspace}, _from, state), do: {:reply, :ok, state}

  def handle_call({:subscribe, _pid}, _from, state),
    do: {:reply, {:ok, self(), self(), :running}, state}
end

defmodule CaseinWeb.DesktopSessionPickerTest do
  use ExUnit.Case, async: true

  alias CaseinWeb.DesktopSessionPickerTest.PowerShellSessionStub

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Casein.Workspaces.Scratch
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.SessionBarVM
  alias CaseinWeb.WorkspaceLive.Show.Sidebar
  alias CaseinWeb.WorkspaceLive.Show.WorkspaceHeader

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

  test "refreshing synthetic desktop windows does not invoke tmux" do
    start_supervised!(PowerShellSessionStub)
    socket = desktop_socket()

    assert {:noreply, refreshed} =
             Show.handle_event("tmux:refresh_windows", %{}, socket)

    assert refreshed.assigns.windows_sidebar_tree == []
  end

  test "desktop overflow exposes native-safe controls only" do
    html =
      render_component(&WorkspaceHeader.header_overflow_menu/1,
        desktop_terminal?: true,
        workspace: %{id: Scratch.id(), status: :running, branch: nil},
        workspace_start_error: nil,
        tab: "terminal",
        host_loc: {:ok, {:local, System.user_home!()}},
        tmux_mutations_enabled?: false,
        tmux_window_tabs: [],
        terminal_mode: :raw_ghostty,
        tmux_session: "desktop",
        terminal_sid: Scratch.id(),
        active_window_pane_count: 1
      )

    assert html =~ "Restart terminal"
    refute html =~ "Stop workspace"
    refute html =~ "Refresh windows"
    refute html =~ "Panes"
  end

  test "overflow exposes a persistent accessible agent approval announcement" do
    html =
      render_component(&WorkspaceHeader.header_overflow_menu/1,
        desktop_terminal?: true,
        workspace: %{id: Scratch.id(), status: :running, branch: nil},
        workspace_start_error: nil,
        tab: "terminal",
        host_loc: {:ok, {:local, System.user_home!()}},
        tmux_mutations_enabled?: false,
        tmux_window_tabs: [],
        terminal_mode: :raw_ghostty,
        tmux_session: "desktop",
        terminal_sid: Scratch.id(),
        active_window_pane_count: 1,
        notif_unread_count: 1,
        agent_approval_count: 2
      )

    assert html =~ ~s(id="agent-approval-announcer-__scratch__")
    assert html =~ ~s(aria-live="assertive")
    assert html =~ "2 agent approvals waiting in Notifications."
    assert html =~ ~s(id="notifications-open-__scratch__-count")
    assert html =~ ~r/id="notifications-open-__scratch__-count"[^>]*>\s*3\s*<\/span>/
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
