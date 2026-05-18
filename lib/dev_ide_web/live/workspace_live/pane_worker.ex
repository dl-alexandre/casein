defmodule DevIdeWeb.WorkspaceLive.PaneWorker do
  @moduledoc """
  Per-pane owner of a `Ghostty.Terminal` and `Ghostty.PTY` pair.

  Both processes send untagged messages to their `:owner` (`{:data, ...}`
  from the PTY, `{:pty_write, ...}` from the terminal). Owning them in a
  per-pane worker lets us:

  * retag PTY output as `{:pty_data, pane_id, data}` so the LiveView
    can multiplex many panes;
  * write terminal query responses (`{:pty_write, data}`) back to *this
    pane's* PTY directly, instead of bleeding to whichever pane the LV
    happens to think is focused.

  The worker is linked to its parent LiveView (via `GenServer.start_link`)
  and to its term + PTY (via their respective `start_link` calls inside
  `init/1`). If the LV dies, the worker dies, and the term + PTY die. If
  either child dies the worker traps the EXIT and reports
  `{:pty_exit, pane_id, reason}` to the LV before stopping `:normal`.

  The `reason` (third element) is one of `:terminal_died`, `:pty_died`, or
  `:process_died`, allowing the parent to distinguish the source of the exit
  for observability / audit purposes.
  """
  use GenServer

  @type opt ::
          {:parent, pid()}
          | {:pane_id, String.t()}
          | {:tmux_session, String.t()}
          | {:cwd, String.t()}
          | {:cols, pos_integer()}
          | {:rows, pos_integer()}

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the `{term_pid, pty_pid}` owned by this worker."
  @spec get_handles(GenServer.server()) :: {pid(), pid()}
  def get_handles(worker), do: GenServer.call(worker, :get_handles)

  @doc "Resize both the terminal and the PTY in lock-step."
  @spec resize(GenServer.server(), pos_integer(), pos_integer()) :: :ok
  def resize(worker, cols, rows), do: GenServer.call(worker, {:resize, cols, rows})

  @impl true
  def init(opts) do
    parent = Keyword.fetch!(opts, :parent)
    pane_id = Keyword.fetch!(opts, :pane_id)
    tmux_session = Keyword.fetch!(opts, :tmux_session)
    cwd = Keyword.get(opts, :cwd, ".")
    cols = Keyword.fetch!(opts, :cols)
    rows = Keyword.fetch!(opts, :rows)

    Process.flag(:trap_exit, true)

    # Every pane owns its own tmux session — `-A` attaches if it already
    # exists (e.g. after a BEAM restart) so the user's running shell
    # survives across reconnects. No `tmux split-window`; the split is
    # a UI concept handled by the LV's layout tree.
    tmux_invocation = [
      "tmux",
      "new-session",
      "-A",
      "-s",
      tmux_session,
      "-x",
      to_string(cols),
      "-y",
      to_string(rows)
    ]

    # Two wrappers around the tmux invocation, in this order from the outside:
    #
    #   1. WorkspaceSource.prepare_local_argv(_, tty: true) — on devbox this
    #      prepends `docker compose exec <service>` so the tmux server runs
    #      inside the manager-owned workspace container (see Terminals.Session
    #      for the full lifecycle rationale). Falls back to host tmux when the
    #      container image lacks tmux, per Terminals.Tmux.container_has_tmux?/1.
    #
    #   2. `env TERM=xterm-256color` — Ghostty.PTY has no :env option, so the
    #      child inherits BEAM's env (no TERM under systemd). Bare tmux then
    #      fails with "open terminal failed: terminal does not support clear".
    #      Match Terminals.Session, which sets the same TERM via erlexec.
    pty_argv =
      ["env", "TERM=xterm-256color" | tmux_invocation]
      |> then(fn argv ->
        if DevIDE.Terminals.Tmux.container_has_tmux?(cwd) do
          DevIDE.WorkspaceSource.prepare_local_argv(argv, tty: true)
        else
          argv
        end
      end)

    [cmd | pty_args] = pty_argv

    # Cap scrollback per pane to keep memory bounded with many panes.
    # Ghostty's default is 10_000 lines; we settle for 5_000 (config
    # override at `:dev_ide, :pane_max_scrollback`). At ~80 bytes/cell
    # × 200 cols × 5_000 rows ≈ 80 MB worst case, but typical content
    # is far smaller.
    max_scrollback =
      Application.get_env(:dev_ide, :pane_max_scrollback, 5_000)

    with {:ok, term} <-
           Ghostty.Terminal.start_link(
             cols: cols,
             rows: rows,
             max_scrollback: max_scrollback
           ),
         {:ok, pty} <-
           Ghostty.PTY.start_link(cmd: cmd, args: pty_args, cols: cols, rows: rows) do
      {:ok, %{parent: parent, pane_id: pane_id, term: term, pty: pty}}
    else
      {:error, reason} -> {:stop, {:start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:get_handles, _from, state) do
    {:reply, {state.term, state.pty}, state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    if Process.alive?(state.term), do: Ghostty.Terminal.resize(state.term, cols, rows)
    if Process.alive?(state.pty), do: Ghostty.PTY.resize(state.pty, cols, rows)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:data, data}, state) when is_binary(data) do
    send(state.parent, {:pty_data, state.pane_id, data})
    {:noreply, state}
  end

  # Term query responses (e.g. cursor-position reports). Stay inside the
  # worker and write to *this* pane's PTY — no cross-pane bleed.
  def handle_info({:pty_write, data}, state) when is_binary(data) do
    if Process.alive?(state.pty), do: Ghostty.PTY.write(state.pty, data)
    {:noreply, state}
  end

  def handle_info({:exit, status}, state) do
    send(state.parent, {:pty_exit, state.pane_id, status})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _from, reason}, state) when reason in [:normal, :shutdown] do
    {:noreply, state}
  end

  def handle_info({:EXIT, from, _reason}, state) do
    which =
      cond do
        from == state.term -> :terminal_died
        from == state.pty -> :pty_died
        true -> :process_died
      end

    # Send one of the three distinguished atoms so callers (the LV) can
    # tell terminal vs. PTY death apart for future telemetry/audit.
    send(state.parent, {:pty_exit, state.pane_id, which})
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
