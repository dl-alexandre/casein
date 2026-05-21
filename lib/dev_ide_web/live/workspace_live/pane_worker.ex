defmodule DevIdeWeb.WorkspaceLive.PaneWorker do
  @moduledoc """
  Per-pane owner of a `Ghostty.Terminal` plus a writable terminal backend.

  The default backend is `DevIDE.Terminals.SessionOwner`, so the LiveView
  Ghostty pane and any raw channel joins consume the same canonical transport
  boundary. `:shared_session` and legacy `:ghostty_pty` remain available for
  tests and rollback. Owning the terminal/backend pair in a per-pane worker
  lets us:

  * retag PTY output as `{:pty_data, pane_id, data}` so the LiveView
    can multiplex many panes;
  * write terminal query responses (`{:pty_write, data}`) back to *this
    pane's* PTY directly, instead of bleeding to whichever pane the LV
    happens to think is focused.

  The worker is linked to its parent LiveView (via `GenServer.start_link`)
  and to its term + backend (via their respective `start_link` calls inside
  `init/1`). If the LV dies, the worker dies, and the term/backend relation is
  cleaned up. If either child dies the worker traps the EXIT and reports
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
          | {:workspace_id, String.t()}
          | {:workspace_key, String.t()}
          | {:session_sid, String.t()}
          | {:loc, DevIDE.Terminals.Session.loc()}
          | {:backend, :ghostty_pty | :shared_session | :session_owner}
          | {:session_module, module()}
          | {:terminal_module, module()}
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
    backend = Keyword.get(opts, :backend, :ghostty_pty)
    session_module = Keyword.get(opts, :session_module, DevIDE.Terminals.Session)
    terminal_module = Keyword.get(opts, :terminal_module, DevIDE.Terminals)

    Process.flag(:trap_exit, true)

    backend_argv = backend_argv(backend, tmux_session, cwd, cols, rows)

    # Cap scrollback per pane to keep memory bounded with many panes.
    # Ghostty's default is 10_000 lines; we settle for 5_000 (config
    # override at `:dev_ide, :pane_max_scrollback`). At ~80 bytes/cell
    # × 200 cols × 5_000 rows ≈ 80 MB worst case, but typical content
    # is far smaller.
    max_scrollback =
      Application.get_env(:dev_ide, :pane_max_scrollback, 5_000)

    with :ok <- guard_raw_backend(backend, cwd),
         {:ok, term} <-
           Ghostty.Terminal.start_link(
             cols: cols,
             rows: rows,
             max_scrollback: max_scrollback
           ),
         {:ok, pty} <-
           start_backend(backend, opts, session_module, terminal_module, backend_argv, cols, rows) do
      {:ok,
       %{
         parent: parent,
         pane_id: pane_id,
         term: term,
         pty: pty,
         backend: backend,
         session_module: session_module,
         terminal_module: terminal_module
       }}
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
    resize_backend(state, cols, rows)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:data, data}, state) when is_binary(data) do
    send(state.parent, {:pty_data, state.pane_id, data})
    {:noreply, state}
  end

  def handle_info({:term_data, _ref, data, :replay}, state) when is_binary(data) do
    send(state.parent, {:pty_data, state.pane_id, data})
    {:noreply, state}
  end

  def handle_info({:term_data, _ref, data}, state) when is_binary(data) do
    send(state.parent, {:pty_data, state.pane_id, data})
    {:noreply, state}
  end

  def handle_info({:terminal_payload, :data, %{data: data}}, state) when is_binary(data) do
    send(state.parent, {:pty_data, state.pane_id, data})
    {:noreply, state}
  end

  def handle_info({:terminal_payload, :exit, reason}, state) do
    send(state.parent, {:pty_exit, state.pane_id, reason})
    {:stop, :normal, state}
  end

  # Term query responses (e.g. cursor-position reports). Stay inside the
  # worker and write to *this* pane's PTY — no cross-pane bleed.
  def handle_info({:pty_write, data}, state) when is_binary(data) do
    write_backend(state, data)
    {:noreply, state}
  end

  def handle_info({:exit, status}, state) do
    send(state.parent, {:pty_exit, state.pane_id, status})
    {:stop, :normal, state}
  end

  def handle_info({:term_exit, _ref, reason}, state) do
    send(state.parent, {:pty_exit, state.pane_id, reason})
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

  @impl true
  def terminate(_reason, %{backend: :shared_session, pty: pid, session_module: session_module})
      when is_pid(pid) do
    session_module.unsubscribe(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, %{backend: :session_owner, pty: pid, terminal_module: terminal_module})
      when is_pid(pid) do
    terminal_module.owner_detach(pid, self())
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # Fail closed on the host-tmux fallback. `container_has_tmux?/1` returns true
  # for pure-local/host mode and for workspace containers that ship tmux; it
  # returns false ONLY when command execution is wrapped into a workspace
  # container that LACKS tmux. The old behavior then silently ran `tmux` on the
  # HOST, dropping the user into a host shell as the shared service user — full
  # cross-user/host access on the shared instance. Refuse instead; the raw
  # terminal surfaces a clear error until the workspace image ships tmux.
  defp guard_raw_backend(:ghostty_pty, cwd) do
    if DevIDE.Terminals.Tmux.container_has_tmux?(cwd) do
      :ok
    else
      {:error, :workspace_image_lacks_tmux}
    end
  end

  defp guard_raw_backend(_backend, _cwd), do: :ok

  defp backend_argv(:session_owner, _tmux_session, _cwd, _cols, _rows), do: nil

  defp backend_argv(:shared_session, _tmux_session, _cwd, _cols, _rows), do: nil

  defp backend_argv(:ghostty_pty, tmux_session, cwd, cols, rows) do
    # Legacy backend: every pane owns its own tmux client PTY. Kept for tests
    # and rollback while production uses the shared Terminals.Session backend.
    #
    # Deterministic per-tab attach: `tmux_session` is now scoped per browser
    # tab (devide_<ws>_u-<id>-<tab>, see WorkspaceLive.Show mount), so each tab
    # attaches to (or creates) its OWN session. A refresh of the same tab
    # reattaches the same name (work survives); separate windows get distinct
    # names and stay independent instead of converging on one session.
    #
    # `-A` attaches if it exists, else creates. No `-D` — refreshing one tab
    # must not detach the user's other live clients; tmux `window-size latest`
    # + `aggressive-resize` (apply_defaults) handle multi-client sizing.
    #
    # `-c <cwd>` is the HOST workspace path. It's correct in host mode, but when
    # we wrap into the workspace container (docker compose exec) that path does
    # not exist inside the container, so the pane's shell can't chdir there and
    # exits immediately ("Terminal exited"). When wrapping, omit -c and let the
    # exec land in the container's own WORKDIR (the mounted workspace).
    base = ["tmux", "new-session", "-A", "-s", tmux_session]
    size = ["-x", to_string(cols), "-y", to_string(rows)]

    tmux_invocation =
      if wraps_into_container?() do
        base ++ size
      else
        base ++ ["-c", cwd] ++ size
      end

    ["env", "TERM=xterm-256color" | tmux_invocation]
    |> then(fn argv ->
      if DevIDE.Terminals.Tmux.container_has_tmux?(cwd) do
        # Pass cwd so the wrapped `docker compose` pins --project-directory —
        # Ghostty.PTY can't set the process cwd, and compose otherwise can't
        # find the workspace project.
        DevIDE.WorkspaceSource.prepare_local_argv(argv, tty: true, cwd: cwd)
      else
        argv
      end
    end)
  end

  # True when the configured WorkspaceSource wraps argv to run inside the
  # workspace container (e.g. `docker compose exec`). Used to decide whether the
  # host cwd is meaningful for the terminal's start directory.
  defp wraps_into_container? do
    DevIDE.WorkspaceSource.prepare_local_argv(["__cwd_probe__"]) != ["__cwd_probe__"]
  end

  defp start_backend(
         :session_owner,
         opts,
         _session_module,
         terminal_module,
         _backend_argv,
         _cols,
         _rows
       ) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    workspace_key = Keyword.fetch!(opts, :workspace_key)
    session_sid = Keyword.fetch!(opts, :session_sid)
    loc = Keyword.fetch!(opts, :loc)
    host_id = Keyword.get(opts, :host_id, "local")
    info = terminal_module.new_shell(workspace_id, session_sid)

    owner_opts =
      [
        mode: :raw,
        host_id: host_id,
        workspace_key: workspace_key,
        loc: loc,
        session_id: session_sid
      ] ++ Keyword.take(opts, [:test_owner])

    with {:ok, owner_pid, _payload} <-
           terminal_module.owner_attach(workspace_id, info, owner_opts) do
      {:ok, owner_pid}
    end
  end

  defp start_backend(
         :shared_session,
         opts,
         session_module,
         _terminal_module,
         _backend_argv,
         _cols,
         _rows
       ) do
    workspace_key = Keyword.fetch!(opts, :workspace_key)
    session_sid = Keyword.fetch!(opts, :session_sid)
    loc = Keyword.fetch!(opts, :loc)

    with {:ok, pid} <- session_module.ensure_started(workspace_key, session_sid, loc),
         {:ok, _ref, _cols, _rows} <- session_module.subscribe(pid) do
      {:ok, pid}
    end
  end

  defp start_backend(
         :ghostty_pty,
         _opts,
         _session_module,
         _terminal_module,
         [cmd | pty_args],
         cols,
         rows
       ) do
    Ghostty.PTY.start_link(cmd: cmd, args: pty_args, cols: cols, rows: rows)
  end

  defp resize_backend(
         %{backend: :session_owner, pty: pid, terminal_module: terminal_module},
         cols,
         rows
       )
       when is_pid(pid) do
    if Process.alive?(pid), do: terminal_module.owner_resize(pid, cols, rows)
  end

  defp resize_backend(
         %{backend: :shared_session, pty: pid, session_module: session_module},
         cols,
         rows
       )
       when is_pid(pid) do
    if Process.alive?(pid), do: session_module.resize(pid, cols, rows)
  end

  defp resize_backend(%{backend: :ghostty_pty, pty: pid}, cols, rows) when is_pid(pid) do
    if Process.alive?(pid), do: Ghostty.PTY.resize(pid, cols, rows)
  end

  defp resize_backend(_state, _cols, _rows), do: :ok

  defp write_backend(%{backend: :session_owner, pty: pid, terminal_module: terminal_module}, data)
       when is_pid(pid) do
    if Process.alive?(pid), do: terminal_module.owner_input(pid, data)
  end

  defp write_backend(%{backend: :shared_session, pty: pid, session_module: session_module}, data)
       when is_pid(pid) do
    if Process.alive?(pid), do: session_module.send_input(pid, data)
  end

  defp write_backend(%{backend: :ghostty_pty, pty: pid}, data) when is_pid(pid) do
    if Process.alive?(pid), do: Ghostty.PTY.write(pid, data)
  end

  defp write_backend(_state, _data), do: :ok
end
