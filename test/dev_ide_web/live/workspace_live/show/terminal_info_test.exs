defmodule DevIdeWeb.WorkspaceLive.Show.TerminalInfoTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Terminals.Tmux
  alias DevIdeWeb.WorkspaceLive.Show
  alias DevIdeWeb.WorkspaceLive.Show.TerminalInfo
  alias TmuxCtl.Test.FakeState

  defmodule ResizeStub do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def handle_call({:resize, cols, rows}, _from, %{test_pid: test_pid} = state) do
      send(test_pid, {:pane_worker_resized, cols, rows})
      {:reply, :ok, state}
    end

    @impl true
    def handle_cast({:set_active, active?}, %{test_pid: test_pid} = state) do
      send(test_pid, {:pane_worker_active, active?})
      {:noreply, state}
    end
  end

  setup do
    previous = %{
      tmux_adapter: Application.get_env(:dev_ide, :tmux_adapter),
      fake_tmux_windows: FakeState.get(:fake_tmux_windows),
      fake_tmux_panes: FakeState.get(:fake_tmux_panes),
      fake_tmux_test_pid: FakeState.get(:fake_tmux_test_pid)
    }

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    FakeState.put(:fake_tmux_test_pid, self())
    FakeState.put(:fake_tmux_windows, %{})
    FakeState.put(:fake_tmux_panes, %{})

    on_exit(fn ->
      FakeState.restore(:fake_tmux_windows, previous.fake_tmux_windows)
      FakeState.restore(:fake_tmux_panes, previous.fake_tmux_panes)
      FakeState.restore(:fake_tmux_test_pid, previous.fake_tmux_test_pid)

      if previous.tmux_adapter,
        do: Application.put_env(:dev_ide, :tmux_adapter, previous.tmux_adapter),
        else: Application.delete_env(:dev_ide, :tmux_adapter)
    end)

    session = Tmux.session_name("alpha", "main")
    {:ok, worker} = start_supervised({ResizeStub, [test_pid: self()]})

    socket =
      base_socket(%{
        tmux_session: session,
        pane_data: %{
          "pane-1" => %{
            worker: worker,
            tmux_session: session,
            cols: 80,
            rows: 24
          }
        }
      })

    %{socket: socket, worker: worker, session: session, pane_id: "pane-1"}
  end

  test "terminal_ready syncs ghostty pane dimensions", %{socket: socket, pane_id: pane_id} do
    assert {:noreply, updated} =
             TerminalInfo.handle_info({:terminal_ready, "ghostty-#{pane_id}", 120, 40}, socket)

    pane = Show.get_pane_data(updated, pane_id)
    assert pane.cols == 120
    assert pane.rows == 40
    assert_receive {:pane_worker_resized, 120, 40}, 1_000
  end

  test "terminal_resize uses the same sync path as terminal_ready", %{
    socket: socket,
    pane_id: pane_id
  } do
    assert {:noreply, updated} =
             TerminalInfo.handle_info({:terminal_resize, "ghostty-#{pane_id}", 100, 30}, socket)

    pane = Show.get_pane_data(updated, pane_id)
    assert pane.cols == 100
    assert pane.rows == 30
    assert_receive {:pane_worker_resized, 100, 30}, 1_000
  end

  test "ignores ready events for non-ghostty component ids", %{socket: socket} do
    assert {:noreply, ^socket} =
             TerminalInfo.handle_info({:terminal_ready, "legacy-pane", 80, 24}, socket)

    refute_receive {:pane_worker_resized, _, _}, 50
  end

  test "skips topology refresh when pane tmux session differs from active session", %{
    socket: socket,
    pane_id: pane_id
  } do
    other_session = Tmux.session_name("alpha", "other")
    socket = Show.update_pane(socket, pane_id, fn p -> %{p | tmux_session: other_session} end)

    assert {:noreply, updated} =
             TerminalInfo.handle_info({:terminal_ready, "ghostty-#{pane_id}", 90, 25}, socket)

    pane = Show.get_pane_data(updated, pane_id)
    assert pane.cols == 90
    assert pane.rows == 25
    assert updated.assigns.tmux_topology_version == 0
    assert_receive {:pane_worker_resized, 90, 25}, 1_000
  end

  test "no-ops when pane data is missing", %{socket: socket} do
    assert {:noreply, ^socket} =
             TerminalInfo.handle_info({:terminal_ready, "ghostty-missing", 80, 24}, socket)

    refute_receive {:pane_worker_resized, _, _}, 50
  end

  test "terminal_active forwards the viewer's active state to its PaneWorker", %{
    socket: socket,
    pane_id: pane_id
  } do
    assert {:noreply, ^socket} =
             TerminalInfo.handle_info({:terminal_active, "ghostty-#{pane_id}", true}, socket)

    assert_receive {:pane_worker_active, true}, 1_000

    assert {:noreply, ^socket} =
             TerminalInfo.handle_info({:terminal_active, "ghostty-#{pane_id}", false}, socket)

    assert_receive {:pane_worker_active, false}, 1_000
  end

  test "terminal_active ignores non-ghostty ids and missing panes", %{socket: socket} do
    assert {:noreply, ^socket} =
             TerminalInfo.handle_info({:terminal_active, "legacy-pane", true}, socket)

    assert {:noreply, ^socket} =
             TerminalInfo.handle_info({:terminal_active, "ghostty-missing", true}, socket)

    refute_receive {:pane_worker_active, _}, 50
  end

  defp base_socket(assigns) do
    %Phoenix.LiveView.Socket{
      endpoint: DevIdeWeb.Endpoint,
      view: DevIdeWeb.WorkspaceLive.Show,
      root_pid: self(),
      assigns: Map.merge(default_assigns(), assigns)
    }
  end

  defp default_assigns do
    %{
      __changed__: %{},
      workspace: %{id: "ws-alpha", name: "alpha"},
      tmux_windows: [],
      tmux_window_tabs: [],
      tmux_panes: [],
      tmux_active_window_id: nil,
      tmux_active_pane_id: nil,
      tmux_topology_version: 0,
      tmux_topology_structure_version: 0,
      tmux_topology_generation: 0,
      window_zoomed?: false,
      page_title: "test",
      default_terminal_sid: "main",
      terminal_sid: "main",
      host_path: nil,
      shell_button_label: "Shell",
      shell_button_detail: nil,
      active_window_pane_count: 1
    }
  end
end
