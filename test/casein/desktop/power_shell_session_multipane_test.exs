defmodule Casein.Desktop.PowerShellSessionMultipaneTest do
  use ExUnit.Case, async: true

  alias Casein.Desktop.PowerShellSession

  defmodule FakeTransport do
    @behaviour Casein.Desktop.PowerShellPane.Transport

    @impl true
    def start(_cwd, _env, _cols, _rows, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      {:ok, term} = Agent.start_link(fn -> {:owner, test_pid, :terminal} end)
      {:ok, pty} = Agent.start_link(fn -> {:owner, test_pid, :pty} end)
      send(test_pid, {:transport_started, term, pty})
      {:ok, term, pty}
    end

    @impl true
    def write(pty, data) do
      send(test_pid(pty), {:transport_write, pty, IO.iodata_to_binary(data)})
      :ok
    end

    @impl true
    def resize(term, pty, cols, rows) do
      send(test_pid(term), {:transport_resize, term, pty, cols, rows})
      :ok
    end

    @impl true
    def terminal_write(term, data) do
      send(test_pid(term), {:terminal_write, term, IO.iodata_to_binary(data)})
      :ok
    end

    @impl true
    def close(term, pty) do
      receiver = test_pid(term)
      send(receiver, {:transport_closed, term, pty})
      if Process.alive?(pty), do: Agent.stop(pty)
      if Process.alive?(term), do: Agent.stop(term)
      :ok
    end

    defp test_pid(agent) do
      Agent.get(agent, fn
        {:owner, pid, _kind} -> pid
        _state -> raise "fake transport owner is unavailable"
      end)
    end
  end

  test "supervises multiple owned panes with create/focus/close topology" do
    session = start_session()
    assert_receive {:transport_started, _term0, _pty0}

    topology = GenServer.call(session, :topology)

    assert %{
             session: %{id: session_id, alive?: true},
             windows: [%{id: window_id, active?: true}],
             panes: [%{id: pane0, window_id: pane0_window, role: "operator", active?: true}]
           } = topology

    assert pane0_window == window_id

    assert {:ok, %{pane: %{id: pane1, role: "agent", active?: false}, topology: topology}} =
             GenServer.call(session, {:create_pane, window_id, [role: "agent"]})

    assert_receive {:transport_started, _term1, pty1}

    assert %{panes: panes} = topology
    assert Enum.map(panes, & &1.id) == [pane0, pane1]
    assert Enum.count(panes, & &1.active?) == 1

    assert {:ok, focused} = GenServer.call(session, {:focus_pane, pane1})
    assert %{panes: [%{id: ^pane0, active?: false}, %{id: ^pane1, active?: true}]} = focused

    assert :ok = GenServer.call(session, {:input, pane1, "Write-Output agent\r"})
    assert_receive {:transport_write, ^pty1, "Write-Output agent\r"}

    assert {:ok, %{window: %{id: window1}, pane: %{id: pane2}, topology: multi_window}} =
             GenServer.call(session, {:create_window, [name: "Agent", role: "verify"]})

    assert_receive {:transport_started, _term2, _pty2}
    assert window1 != window_id
    assert length(multi_window.windows) == 2
    assert length(multi_window.panes) == 3

    assert {:error, :invalid_window_target} =
             GenServer.call(session, {:create_pane, window_id <> "-missing", []})

    assert {:error, :invalid_pane_target} =
             GenServer.call(session, {:focus_pane, pane0 <> "-missing"})

    assert {:ok, after_close} = GenServer.call(session, {:close_pane, pane1})
    assert_receive {:transport_closed, _closed_term, ^pty1}
    assert Enum.map(after_close.panes, & &1.id) == [pane0, pane2]
    refute Enum.any?(after_close.panes, &(&1.id == pane1))

    # Closing the last pane in a window drops that window.
    assert {:ok, pruned} = GenServer.call(session, {:close_pane, pane2})
    assert Enum.map(pruned.windows, & &1.id) == [window_id]
    assert Enum.map(pruned.panes, & &1.id) == [pane0]
    assert hd(pruned.panes).active?

    assert {:error, :last_native_pane} = GenServer.call(session, {:close_pane, pane0})
    assert String.starts_with?(session_id, "native-session-")
  end

  test "routes subscribe handles and untargeted input through the focused pane" do
    session = start_session()
    assert_receive {:transport_started, term0, pty0}

    assert {:ok, ^term0, ^pty0, :running} = GenServer.call(session, {:subscribe, self()})

    topology = GenServer.call(session, :topology)
    window_id = hd(topology.windows).id
    pane0 = hd(topology.panes).id

    assert {:ok, %{pane: %{id: pane1}}} =
             GenServer.call(session, {:create_pane, window_id, [role: "agent"]})

    assert_receive {:transport_started, term1, pty1}

    assert {:ok, _} = GenServer.call(session, {:focus_pane, pane1})
    assert {:ok, ^term1, ^pty1, :running} = GenServer.call(session, {:subscribe, self()})

    assert :ok = GenServer.call(session, {:input, "focused only\r"})
    assert_receive {:transport_write, ^pty1, "focused only\r"}
    refute_received {:transport_write, ^pty0, _}

    send(pane_pid(session, pane1), {:data, "from-agent"})
    assert_receive {:desktop_terminal_output, "from-agent"}

    send(pane_pid(session, pane0), {:data, "from-operator"})
    refute_received {:desktop_terminal_output, "from-operator"}
  end

  test "capture and resize remain pane-local after multipane ownership" do
    session = start_session()
    assert_receive {:transport_started, _term0, _pty0}

    topology = GenServer.call(session, :topology)
    window_id = hd(topology.windows).id
    pane0 = hd(topology.panes).id

    assert {:ok, %{pane: %{id: pane1}}} =
             GenServer.call(session, {:create_pane, window_id, []})

    assert_receive {:transport_started, term1, pty1}

    assert :ok = GenServer.call(session, {:resize, pane1, 120, 40})
    assert_receive {:transport_resize, ^term1, ^pty1, 120, 40}

    send(pane_pid(session, pane1), {:data, "pane-one-capture"})
    _ = :sys.get_state(session)
    assert {:ok, "pane-one-capture"} = GenServer.call(session, {:capture, pane1})
    assert {:ok, ""} = GenServer.call(session, {:capture, pane0})
  end

  defp start_session do
    name = :"native-multipane-#{System.unique_integer([:positive])}"

    start_supervised!(
      {PowerShellSession,
       cwd: File.cwd!(),
       workspace: %{id: "multipane-#{System.unique_integer([:positive])}"},
       name: name,
       transport: FakeTransport,
       transport_opts: [test_pid: self()]}
    )
  end

  defp pane_pid(session, pane_id) do
    state = :sys.get_state(session)
    Map.fetch!(state.panes, pane_id).pid
  end
end
