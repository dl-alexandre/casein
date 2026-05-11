defmodule DevIDE.Terminals.Session do
  @moduledoc """
  PTY-attached tmux session.

  Starts `tmux new-session -A -s <name>` under a PTY allocated by `erlexec`.
  The `-A` flag means "attach if exists, create otherwise" — this is the
  reconnect mechanism: Session processes can come and go, but the underlying
  tmux session persists until killed.

  One Session per `(workspace, sid)` pair, keyed in `DevIDE.Terminals.Registry`.
  Subscribers receive `{:term_data, ref, binary}` and `{:term_exit, ref, reason}`.
  """

  use GenServer
  require Logger

  alias DevIDE.Terminals.Tmux

  @default_rows 40
  @default_cols 120

  ## Public API

  def child_spec({_workspace, _sid, _cwd} = arg) do
    %{id: {__MODULE__, arg}, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
  end

  def start_link({workspace, sid, cwd}) do
    name = via(workspace, sid)
    GenServer.start_link(__MODULE__, {workspace, sid, cwd}, name: name)
  end

  def via(workspace, sid),
    do: {:via, Registry, {DevIDE.Terminals.Registry, {workspace, sid}}}

  def whereis(workspace, sid) do
    case Registry.lookup(DevIDE.Terminals.Registry, {workspace, sid}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Returns the Session pid, starting one if not already running.
  """
  def ensure_started(workspace, sid, cwd) do
    case whereis(workspace, sid) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        DynamicSupervisor.start_child(
          DevIDE.Terminals.Supervisor,
          {__MODULE__, {workspace, sid, cwd}}
        )
    end
  end

  def subscribe(pid), do: GenServer.call(pid, {:subscribe, self()})
  def input(pid, data) when is_binary(data), do: GenServer.cast(pid, {:input, data})
  def resize(pid, cols, rows), do: GenServer.cast(pid, {:resize, cols, rows})
  def stop(pid), do: GenServer.stop(pid, :normal)

  ## Callbacks

  @impl true
  def init({workspace, sid, cwd}) do
    tmux_session = Tmux.session_name(workspace, sid)
    cmd = ~c"tmux new-session -A -s #{tmux_session} -x #{@default_cols} -y #{@default_rows}"

    # In PTY mode, erlexec routes all child output through the :stderr channel.
    # Capture both so this code is robust to either routing.
    opts = [
      :stdin,
      :monitor,
      :pty,
      {:cd, to_charlist(cwd)},
      {:env, [{~c"TERM", ~c"xterm-256color"}]},
      {:stdout, self()},
      {:stderr, self()}
    ]

    case :exec.run(cmd, opts) do
      {:ok, exec_pid, ospid} ->
        _ = :exec.winsz(ospid, @default_rows, @default_cols)

        Logger.debug("terminal session started",
          workspace: workspace,
          sid: sid,
          tmux: tmux_session,
          ospid: ospid
        )

        ref = make_ref()

        {:ok,
         %{
           ref: ref,
           workspace: workspace,
           sid: sid,
           tmux: tmux_session,
           exec_pid: exec_pid,
           ospid: ospid,
           subscriber: nil,
           subscriber_mon: nil,
           cols: @default_cols,
           rows: @default_rows
         }}

      {:error, reason} ->
        {:stop, {:exec_failed, reason}}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    if state.subscriber, do: Process.demonitor(state.subscriber_mon, [:flush])
    mon = Process.monitor(pid)

    {:reply, {:ok, state.ref, state.cols, state.rows},
     %{state | subscriber: pid, subscriber_mon: mon}}
  end

  @impl true
  def handle_cast({:input, data}, state) do
    :exec.send(state.ospid, data)
    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) when is_integer(cols) and is_integer(rows) do
    cols = max(min(cols, 500), 1)
    rows = max(min(rows, 500), 1)
    _ = :exec.winsz(state.ospid, rows, cols)
    {:noreply, %{state | cols: cols, rows: rows}}
  end

  @impl true
  def handle_info({:stdout, _ospid, data}, %{subscriber: pid, ref: ref} = state)
      when is_pid(pid) do
    send(pid, {:term_data, ref, data})
    {:noreply, state}
  end

  def handle_info({:stderr, _ospid, data}, %{subscriber: pid, ref: ref} = state)
      when is_pid(pid) do
    send(pid, {:term_data, ref, data})
    {:noreply, state}
  end

  def handle_info({:stdout, _ospid, _data}, state), do: {:noreply, state}
  def handle_info({:stderr, _ospid, _data}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscriber: pid} = state) do
    {:noreply, %{state | subscriber: nil, subscriber_mon: nil}}
  end

  def handle_info({:DOWN, ospid, :process, _pid, reason}, %{ospid: ospid} = state) do
    if state.subscriber, do: send(state.subscriber, {:term_exit, state.ref, reason})
    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
