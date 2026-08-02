defmodule Casein.Desktop.PowerShellPane do
  @moduledoc """
  Independently owns one native PowerShell terminal and its ConPTY process tree.

  A pane keeps stable product identity across transport recovery. Closing the
  owner synchronously closes its PTY, whose Windows bridge owns all descendants
  through a kill-on-close Job Object.
  """

  use GenServer

  alias Casein.Desktop.AgentEnvironment
  alias Casein.Desktop.PowerShellPane.GhosttyTransport

  @default_cols 100
  @default_rows 30
  @capture_bytes 64 * 1024
  @pane_roles ~w(operator agent verify preview)

  @type identity :: %{session: String.t(), window: String.t(), pane: String.t()}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def snapshot(pane), do: GenServer.call(pane, :snapshot)
  def capture(pane), do: GenServer.call(pane, :capture)
  def send_input(pane, data) when is_binary(data), do: GenServer.call(pane, {:input, data})
  def resize(pane, cols, rows), do: GenServer.call(pane, {:resize, cols, rows})
  def set_role(pane, role), do: GenServer.call(pane, {:set_role, role})

  def set_active(pane, active?) when is_boolean(active?),
    do: GenServer.call(pane, {:active, active?})

  def close(pane), do: GenServer.stop(pane, :normal)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    cols = Keyword.get(opts, :cols, @default_cols)
    rows = Keyword.get(opts, :rows, @default_rows)
    role = Keyword.get(opts, :role, "operator")

    with {:ok, ids} <- validate_identity(Keyword.get(opts, :ids)),
         {:ok, cwd} <- validate_cwd(Keyword.get(opts, :cwd)),
         :ok <- validate_size(cols, rows),
         :ok <- validate_role(role),
         {:ok, owner} <- validate_owner(Keyword.get(opts, :owner)),
         {:ok, env} <- agent_environment(Keyword.get(opts, :workspace), cwd),
         transport = Keyword.get(opts, :transport, GhosttyTransport),
         {:ok, term, pty} <-
           transport.start(
             cwd,
             env,
             cols,
             rows,
             Keyword.get(opts, :transport_opts, [])
           ) do
      {:ok,
       %{
         ids: ids,
         cwd: cwd,
         workspace: Keyword.get(opts, :workspace),
         owner: owner,
         owner_ref: Process.monitor(owner),
         transport: transport,
         transport_opts: Keyword.get(opts, :transport_opts, []),
         term: term,
         pty: pty,
         cols: cols,
         rows: rows,
         role: role,
         active?: Keyword.get(opts, :active?, false),
         status: :running,
         capture: <<>>
       }}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_from(state), state}
  def handle_call(:capture, _from, state), do: {:reply, {:ok, state.capture}, state}

  def handle_call({:input, data}, _from, state) do
    {:reply, state.transport.write(state.pty, data), state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    with :ok <- validate_size(cols, rows),
         :ok <- state.transport.resize(state.term, state.pty, cols, rows) do
      {:reply, :ok, %{state | cols: cols, rows: rows}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_role, role}, _from, state) do
    case validate_role(role) do
      :ok -> {:reply, :ok, %{state | role: role}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:active, active?}, _from, state),
    do: {:reply, :ok, %{state | active?: active?}}

  @impl true
  def handle_info({:data, data}, state) do
    :ok = state.transport.terminal_write(state.term, data)
    send(state.owner, {:native_pane_output, state.ids.pane, data})
    {:noreply, %{state | capture: retain_capture(state.capture, data)}}
  end

  def handle_info({:pty_write, data}, state) when is_binary(data) do
    :ok = state.transport.write(state.pty, data)
    {:noreply, state}
  end

  def handle_info({:exit, reason}, state), do: recover_transport(state, reason)

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, reason}, %{pty: pid} = state), do: recover_transport(state, reason)
  def handle_info({:EXIT, pid, reason}, %{term: pid} = state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state.transport.close(state.term, state.pty)
  end

  defp recover_transport(state, reason) do
    :ok = state.transport.close(state.term, state.pty)

    with {:ok, env} <- agent_environment(state.workspace, state.cwd),
         {:ok, term, pty} <-
           state.transport.start(
             state.cwd,
             env,
             state.cols,
             state.rows,
             state.transport_opts
           ) do
      updated = %{state | term: term, pty: pty, status: :running}
      send(updated.owner, {:native_pane_restarted, updated.ids.pane, term, pty})
      {:noreply, updated}
    else
      {:error, restart_reason} ->
        updated = %{state | status: {:exited, {reason, restart_reason}}}
        send(updated.owner, {:native_pane_exit, updated.ids.pane, {reason, restart_reason}})
        {:noreply, updated}
    end
  end

  defp snapshot_from(state) do
    %{
      id: state.ids.pane,
      window_id: state.ids.window,
      session_id: state.ids.session,
      role: state.role,
      active?: state.active?,
      cwd: state.cwd,
      cols: state.cols,
      rows: state.rows,
      status: state.status
    }
  end

  defp validate_identity(%{session: session, window: window, pane: pane} = ids)
       when is_binary(session) and session != "" and is_binary(window) and window != "" and
              is_binary(pane) and pane != "",
       do: {:ok, ids}

  defp validate_identity(_ids), do: {:error, :invalid_native_identity}

  defp validate_cwd(cwd) when is_binary(cwd) and cwd != "" do
    if File.dir?(cwd), do: {:ok, cwd}, else: {:error, :invalid_native_cwd}
  end

  defp validate_cwd(_cwd), do: {:error, :invalid_native_cwd}
  defp validate_owner(owner) when is_pid(owner), do: {:ok, owner}
  defp validate_owner(_owner), do: {:error, :invalid_native_owner}

  defp validate_size(cols, rows)
       when is_integer(cols) and cols >= 1 and cols <= 500 and is_integer(rows) and rows >= 1 and
              rows <= 500,
       do: :ok

  defp validate_size(_cols, _rows), do: {:error, :invalid_terminal_size}
  defp validate_role(role) when role in @pane_roles, do: :ok
  defp validate_role(_role), do: {:error, :invalid_pane_role}

  defp agent_environment(nil, _cwd), do: {:ok, %{}}
  defp agent_environment(workspace, cwd), do: AgentEnvironment.build(workspace, cwd)

  defp retain_capture(previous, data) do
    capture = previous <> IO.iodata_to_binary(data)
    size = byte_size(capture)

    if size > @capture_bytes,
      do: binary_part(capture, size - @capture_bytes, @capture_bytes),
      else: capture
  end
end
