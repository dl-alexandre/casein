defmodule DevIDE.Desktop.PowerShellSession do
  @moduledoc """
  Application-owned PowerShell session used by the native Windows desktop UI.

  The terminal and process transport deliberately outlive any one LiveView so
  browser reconnects retain the same shell process, variables, and working
  directory.
  """

  use GenServer

  alias DevIDE.Desktop.AgentEnvironment

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Ensures the desktop shell is supervised in the selected workspace."
  def ensure_started(cwd \\ nil, workspace \\ nil) do
    cwd = normalize_cwd(cwd)

    case Process.whereis(@name) do
      nil ->
        case Supervisor.start_child(
               DevIde.Supervisor,
               {__MODULE__, cwd: cwd, workspace: workspace}
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, :already_present} -> :ok
          {:error, reason} -> {:error, reason}
        end

      pid ->
        GenServer.call(pid, {:ensure_workspace, cwd, workspace})
    end
  end

  @doc "Subscribes the caller and returns the emulator and process handles."
  def subscribe do
    GenServer.call(@name, {:subscribe, self()})
  end

  def status, do: GenServer.call(@name, :status)

  @doc "Restarts the native shell in the given workspace directory."
  def restart(cwd \\ nil, workspace \\ nil),
    do: GenServer.call(@name, {:restart, normalize_cwd(cwd), workspace})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    cwd = Keyword.fetch!(opts, :cwd)
    workspace = Keyword.get(opts, :workspace)

    case start_transport(cwd, workspace) do
      {:ok, term, pty} ->
        {:ok,
         %{
           term: term,
           pty: pty,
           cwd: cwd,
           workspace: workspace,
           subscribers: %{},
           status: :running
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    state = monitor_subscriber(state, pid)
    {:reply, {:ok, state.term, state.pty, state.status}, state}
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:ensure_workspace, cwd, workspace}, _from, state)
      when state.cwd == cwd and state.workspace == workspace,
      do: {:reply, :ok, state}

  def handle_call({:ensure_workspace, cwd, workspace}, _from, state) do
    restart_transport(state, cwd, workspace)
  end

  def handle_call({:restart, cwd, workspace}, _from, state) do
    restart_transport(state, cwd, workspace)
  end

  @impl true
  def handle_info({:data, data}, state) do
    :ok = Ghostty.Terminal.write(state.term, data)
    notify(state, {:desktop_terminal_output, data})
    {:noreply, state}
  end

  def handle_info({:pty_write, data}, state) when is_binary(data) do
    :ok = Ghostty.PTY.write(state.pty, data)
    {:noreply, state}
  end

  def handle_info({:exit, reason}, state) do
    recover_transport(state, reason)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  def handle_info({:EXIT, pid, reason}, %{pty: pid} = state) do
    recover_transport(state, reason)
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

  defp restart_transport(state, cwd, workspace) do
    _ = close_transport(state)

    case start_transport(cwd, workspace) do
      {:ok, term, pty} ->
        updated = %{
          state
          | term: term,
            pty: pty,
            cwd: cwd,
            workspace: workspace,
            status: :running
        }

        notify(updated, {:desktop_terminal_restarted, term, pty})
        {:reply, :ok, updated}

      {:error, reason} ->
        updated = %{state | status: {:error, reason}}
        notify(updated, {:desktop_terminal_exit, reason})
        {:reply, {:error, reason}, updated}
    end
  end

  defp recover_transport(state, reason) do
    case start_transport(state.cwd, state.workspace) do
      {:ok, term, pty} ->
        updated = %{state | term: term, pty: pty, status: :running}
        notify(updated, {:desktop_terminal_restarted, term, pty})
        {:noreply, updated}

      {:error, restart_reason} ->
        updated = %{state | status: {:exited, {reason, restart_reason}}}
        notify(updated, {:desktop_terminal_exit, {reason, restart_reason}})
        {:noreply, updated}
    end
  end

  defp start_transport(cwd, workspace) do
    with {:ok, env} <- agent_environment(workspace, cwd),
         {:ok, term} <- Ghostty.Terminal.start_link(cols: 100, rows: 30),
         {:ok, pty} <- Ghostty.PTY.start_link(cwd: cwd, env: env) do
      {:ok, term, pty}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp agent_environment(nil, _cwd), do: {:ok, %{}}
  defp agent_environment(workspace, cwd), do: AgentEnvironment.build(workspace, cwd)

  defp close_transport(state) do
    if is_pid(state.pty) and Process.alive?(state.pty), do: Ghostty.PTY.close(state.pty)
    if is_pid(state.term) and Process.alive?(state.term), do: GenServer.stop(state.term)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp normalize_cwd(cwd) when is_binary(cwd) and cwd != "" do
    if File.dir?(cwd), do: cwd, else: File.cwd!()
  end

  defp normalize_cwd(_cwd), do: File.cwd!()
end
