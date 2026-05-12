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

  # Retained tail of pane output, replayed to a new subscriber on attach.
  # This is what makes resume-after-disconnect (product.md §8.2, §12 row 5)
  # show the operator what happened while they were gone, instead of an
  # empty pane that picks up only future bytes.
  @buffer_bytes 64 * 1024

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

    # If a tmux session already exists for this (workspace, sid) — which
    # happens when this Session GenServer is being rebuilt after a BEAM
    # restart while tmux persisted — grab the pane's scrollback before we
    # attach. capture-pane reads from tmux's own ring buffer; once we
    # re-attach the pane repaints only its current screen, so the
    # historical bytes would otherwise be unrecoverable on the cockpit
    # side. Soft-fails to <<>> if anything goes wrong — the worst-case is
    # behaviour identical to before this change (audit_remote.md CC-3).
    seeded_buffer =
      if Tmux.session_exists?(tmux_session) do
        Tmux.capture_scrollback(tmux_session)
        |> trim_to(@buffer_bytes)
      else
        <<>>
      end

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
           rows: @default_rows,
           buffer: seeded_buffer
         }}

      {:error, reason} ->
        {:stop, {:exec_failed, reason}}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    if state.subscriber, do: Process.demonitor(state.subscriber_mon, [:flush])
    mon = Process.monitor(pid)

    # Replay retained output before live forwarding resumes. The new
    # subscriber sees what actually happened — not a reconstruction.
    if state.buffer != <<>>, do: send(pid, {:term_data, state.ref, state.buffer})

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
  def handle_info({:stdout, _ospid, data}, state), do: {:noreply, ingest(state, data)}
  def handle_info({:stderr, _ospid, data}, state), do: {:noreply, ingest(state, data)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscriber: pid} = state) do
    {:noreply, %{state | subscriber: nil, subscriber_mon: nil}}
  end

  def handle_info({:DOWN, ospid, :process, _pid, reason}, %{ospid: ospid} = state) do
    if state.subscriber, do: send(state.subscriber, {:term_exit, state.ref, reason})
    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{ospid: ospid}) do
    _ = :exec.kill(ospid, 15)
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Internal

  # Append fresh PTY output to the retained buffer (capped at @buffer_bytes)
  # and forward live to the current subscriber if any. Buffering continues
  # even when no subscriber is attached, which is what makes resume work.
  defp ingest(state, data) do
    bin = IO.iodata_to_binary(data)
    if state.subscriber, do: send(state.subscriber, {:term_data, state.ref, bin})
    %{state | buffer: append_buffer(state.buffer, bin, @buffer_bytes)}
  end

  defp append_buffer(buf, bin, cap) do
    new = buf <> bin
    size = byte_size(new)
    if size > cap, do: binary_part(new, size - cap, cap), else: new
  end

  defp trim_to(bin, cap) when byte_size(bin) <= cap, do: bin

  defp trim_to(bin, cap) do
    size = byte_size(bin)
    binary_part(bin, size - cap, cap)
  end
end
