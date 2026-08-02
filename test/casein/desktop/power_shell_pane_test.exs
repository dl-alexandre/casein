defmodule Casein.Desktop.PowerShellPaneTest do
  use ExUnit.Case, async: true

  alias Casein.Desktop.PowerShellPane

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

  test "owns stable pane identity and isolated terminal state" do
    pane = start_pane()
    assert_receive {:transport_started, term, pty}

    assert %{
             id: "native-session-1:pane:7",
             window_id: "native-session-1:window:3",
             session_id: "native-session-1",
             role: "operator",
             active?: true,
             cols: 100,
             rows: 30,
             status: :running
           } = PowerShellPane.snapshot(pane)

    assert :ok = PowerShellPane.send_input(pane, "Write-Output safe\r")
    assert_receive {:transport_write, ^pty, "Write-Output safe\r"}

    assert :ok = PowerShellPane.resize(pane, 132, 44)
    assert_receive {:transport_resize, ^term, ^pty, 132, 44}

    assert :ok = PowerShellPane.set_role(pane, "agent")
    assert :ok = PowerShellPane.set_active(pane, false)

    assert %{role: "agent", active?: false, cols: 132, rows: 44} =
             PowerShellPane.snapshot(pane)

    send(pane, {:data, "retained output"})
    assert_receive {:terminal_write, ^term, "retained output"}
    assert_receive {:native_pane_output, "native-session-1:pane:7", "retained output"}
    _ = :sys.get_state(pane)
    assert {:ok, "retained output"} = PowerShellPane.capture(pane)
  end

  test "validates pane-local mutations" do
    pane = start_pane()
    assert_receive {:transport_started, _term, _pty}

    assert {:error, :invalid_terminal_size} = PowerShellPane.resize(pane, 0, 30)
    assert {:error, :invalid_pane_role} = PowerShellPane.set_role(pane, "agent; stop")
    refute_received {:transport_resize, _, _, _, _}
  end

  test "closing an owner synchronously closes its complete transport" do
    pane = start_pane()
    assert_receive {:transport_started, term, pty}
    ref = Process.monitor(pane)

    assert :ok = PowerShellPane.close(pane)
    assert_receive {:transport_closed, ^term, ^pty}
    assert_receive {:DOWN, ^ref, :process, ^pane, :normal}
    refute Process.alive?(term)
    refute Process.alive?(pty)
  end

  test "transport recovery closes the old tree and preserves product identity" do
    pane = start_pane()
    assert_receive {:transport_started, old_term, old_pty}

    send(pane, {:exit, :shell_crashed})

    assert_receive {:transport_closed, ^old_term, ^old_pty}
    assert_receive {:transport_started, new_term, new_pty}

    assert_receive {:native_pane_restarted, "native-session-1:pane:7", ^new_term, ^new_pty}

    assert %{id: "native-session-1:pane:7", status: :running} =
             PowerShellPane.snapshot(pane)
  end

  test "owner exit deterministically closes the pane transport" do
    owner =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :stop -> :ok
           end
         end}
      )

    pane = start_pane(owner: owner)
    assert_receive {:transport_started, term, pty}
    ref = Process.monitor(pane)

    Process.exit(owner, :shutdown)

    assert_receive {:transport_closed, ^term, ^pty}
    assert_receive {:DOWN, ^ref, :process, ^pane, :normal}
  end

  test "rejects missing stable identity before starting a transport" do
    assert {:error, :invalid_native_identity} =
             PowerShellPane.start_link(
               owner: self(),
               cwd: File.cwd!(),
               ids: %{pane: "pane-only"},
               transport: FakeTransport,
               transport_opts: [test_pid: self()]
             )

    refute_received {:transport_started, _, _}
  end

  defp start_pane(opts \\ []) do
    start_supervised!(
      {PowerShellPane,
       owner: Keyword.get(opts, :owner, self()),
       cwd: File.cwd!(),
       ids: %{
         session: "native-session-1",
         window: "native-session-1:window:3",
         pane: "native-session-1:pane:7"
       },
       active?: true,
       transport: FakeTransport,
       transport_opts: [test_pid: self()]}
    )
  end
end
