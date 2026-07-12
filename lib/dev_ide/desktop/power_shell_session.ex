defmodule DevIDE.Desktop.PowerShellSession do
  @moduledoc """
  Application-owned PowerShell session used by the native Windows desktop UI.

  The terminal and process transport deliberately outlive any one LiveView so
  browser reconnects retain the same shell process, variables, and working
  directory.
  """

  use GenServer

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Ensures the one desktop shell is supervised by the application."
  def ensure_started do
    case Process.whereis(@name) do
      nil ->
        case Supervisor.start_child(DevIde.Supervisor, {__MODULE__, []}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, :already_present} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  @doc "Subscribes the caller and returns the emulator and process handles."
  def subscribe do
    GenServer.call(@name, {:subscribe, self()})
  end

  def status, do: GenServer.call(@name, :status)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    with {:ok, term} <- Ghostty.Terminal.start_link(cols: 100, rows: 30),
         {:ok, pty} <- Ghostty.PTY.start_link() do
      {:ok, %{term: term, pty: pty, subscribers: %{}, status: :running}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    state = monitor_subscriber(state, pid)
    {:reply, {:ok, state.term, state.pty, state.status}, state}
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info({:data, data}, state) do
    :ok = Ghostty.Terminal.write(state.term, data)
    notify(state, {:desktop_terminal_output, data})
    {:noreply, state}
  end

  def handle_info({:exit, reason}, state) do
    notify(state, {:desktop_terminal_exit, reason})
    {:noreply, %{state | status: {:exited, reason}}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  def handle_info({:EXIT, pid, reason}, %{pty: pid} = state) do
    notify(state, {:desktop_terminal_exit, reason})
    {:noreply, %{state | status: {:exited, reason}}}
  end

  def handle_info({:EXIT, pid, reason}, %{term: pid} = state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp monitor_subscriber(state, pid) do
    if Enum.any?(state.subscribers, fn {_ref, subscriber} -> subscriber == pid end) do
      state
    else
      ref = Process.monitor(pid)
      %{state | subscribers: Map.put(state.subscribers, ref, pid)}
    end
  end

  defp notify(state, message) do
    Enum.each(state.subscribers, fn {_ref, pid} -> send(pid, message) end)
  end
end
