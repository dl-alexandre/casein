defmodule DevIdeWeb.WorkspaceLive.PaneWorker do
  @moduledoc """
  Per-pane owner of a `Ghostty.Terminal` plus a writable terminal backend.

  The default backend enters through the terminal facade, so the LiveView Ghostty
  pane and any raw channel joins consume the same canonical transport boundary.
  `:shared_session` and legacy `:ghostty_pty` remain available for tests and
  rollback. Owning the terminal/backend pair in a per-pane worker lets us:

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

  ## Output draining runs here, not on the LiveView

  PTY output is written into the pane's `Ghostty.Terminal` *in this worker
  process* and the resulting `ghostty:render` frame is built here too
  (`DevIdeWeb.TerminalRender`). Only the finished frame is sent to the LV as
  `{:pane_frame, pane_id, payload}`; the LV just forwards it to the browser
  with `push_event`. This matters because `Ghostty.Terminal.write/2` and
  `render_state/1` are synchronous `GenServer.call`s — running them on the LV
  process meant a pane streaming heavy output could block the LiveView channel
  long enough for the client to give up and reload the whole page. Draining
  per-pane in parallel worker processes keeps the LV responsive to input
  (clicks, keys) no matter how much one pane is printing.

  Raw bytes are *also* forwarded to the LV as `{:pty_data, pane_id, data}` for
  cheap byte-stream side channels (OSC52 clipboard, preview-URL detection)
  whose state lives on the LV; those scans are not term calls and are fine
  in-band.

  The `reason` (third element) is one of `:terminal_died`, `:pty_died`, or
  `:process_died`, allowing the parent to distinguish the source of the exit
  for observability / audit purposes.
  """
  use GenServer

  alias DevIDE.Terminals
  alias DevIdeWeb.TerminalRender

  # Output coalescing window. Bursty output (e.g. `cat largefile`, an agent
  # streaming tokens) is buffered and drained into the term + rendered at most
  # once per window, so we make O(1) term writes/renders per pane per frame
  # instead of one per PTY chunk. 8ms (~120fps) halves keystroke-echo latency
  # vs 16ms while still coalescing burst output effectively.
  @flush_interval_ms 8

  # DEC mode 2026 (synchronized output): apps wrap an atomic screen update in
  # BSU … ESU. While one is open we hold the
  # rendered frame back so viewers see only complete frames, never a mid-redraw
  # tear (important with multiple viewers on one PTY). Safety cap forces a flush
  # if an app opens BSU and never closes it.
  @sync_max_defer_ms 120

  @xtversion_response ~r/\A\eP>\|[^\e]*(?:\e\\)\z/
  @device_attrs_response ~r/\A(?:\e\[(?:\?|>)[0-9;]*c)+\z/

  @type opt ::
          {:parent, pid()}
          | {:pane_id, String.t()}
          | {:tmux_session, String.t()}
          | {:workspace_id, String.t()}
          | {:workspace_key, String.t()}
          | {:session_sid, String.t()}
          | {:loc, Terminals.session_loc()}
          | {:backend, :ghostty_pty | :shared_session | :session_owner}
          | {:session_module, module()}
          | {:terminal_module, module()}
          | {:cwd, String.t()}
          | {:cols, pos_integer()}
          | {:rows, pos_integer()}
          | {:terminal_scheme, :dark | :light}
          | {:terminal_preset, String.t()}

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the `{term_pid, pty_pid}` owned by this worker."
  @spec get_handles(GenServer.server()) :: {pid(), pid()}
  def get_handles(worker), do: GenServer.call(worker, :get_handles)

  @doc "Resize both the terminal and the PTY in lock-step."
  @spec resize(GenServer.server(), pos_integer(), pos_integer()) :: :ok
  def resize(worker, cols, rows), do: GenServer.call(worker, {:resize, cols, rows})

  @doc "Force a full render frame from the worker-owned terminal state."
  @spec resync(GenServer.server()) :: :ok
  def resync(worker), do: GenServer.call(worker, :resync)

  @doc """
  Report whether this viewer is currently active (its browser tab is visible
  and focused). Forwarded to the SessionOwner so the shared PTY/tmux is sized to
  the focused viewer rather than the smallest. Fire-and-forget (cast): a
  focus/visibility change must never block on the owner.
  """
  @spec set_active(GenServer.server(), boolean()) :: :ok
  def set_active(worker, active?) when is_boolean(active?),
    do: GenServer.cast(worker, {:set_active, active?})

  @impl true
  def init(opts) do
    parent = Keyword.fetch!(opts, :parent)
    pane_id = Keyword.fetch!(opts, :pane_id)
    tmux_session = Keyword.fetch!(opts, :tmux_session)
    cwd = Keyword.get(opts, :cwd, ".")
    cols = Keyword.fetch!(opts, :cols)
    rows = Keyword.fetch!(opts, :rows)
    backend = Keyword.get(opts, :backend, :session_owner)
    session_module = Keyword.get(opts, :session_module, Terminals.session_backend_module())
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
      scheme = Keyword.get(opts, :terminal_scheme, :dark)
      preset = Keyword.get(opts, :terminal_preset, "catppuccin")

      {:ok,
       %{
         parent: parent,
         pane_id: pane_id,
         term: term,
         pty: pty,
         backend: backend,
         session_module: session_module,
         terminal_module: terminal_module,
         theme_bundle: Terminals.terminal_theme_bundle(preset),
         terminal_scheme: scheme,
         terminal_preset: preset,
         # Output draining state (see moduledoc). `out_buffer` is a reversed
         # iolist of pending PTY bytes; `flush_scheduled?` debounces the timer;
         # `last_cells` is the diff baseline for the next frame. frame_epoch/seq
         # are per-worker render-stream coordinates for client-side resync.
         out_buffer: [],
         flush_scheduled?: false,
         last_cells: nil,
         frame_epoch: 0,
         frame_seq: 0,
         # DEC 2026 synchronized-output gating: `sync_active?` is true while a
         # BSU is open; `sync_timer?` debounces the safety-flush timer.
         sync_active?: false,
         sync_timer?: false
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
    # A resize changes the grid shape, so the next frame must be a full one.
    # Drop the diff baseline and repaint immediately so a fit/resize does not
    # leave the browser waiting for the next byte of PTY output.
    {:reply, :ok, state |> Map.put(:last_cells, nil) |> push_frame(force_full?: true)}
  end

  def handle_call(:resync, _from, state) do
    {:reply, :ok, state |> Map.put(:last_cells, nil) |> push_frame(force_full?: true)}
  end

  @impl true
  def handle_cast({:set_active, active?}, state) when is_boolean(active?) do
    active_backend(state, active?)
    {:noreply, state}
  end

  @impl true
  def handle_info({:data, data}, state) when is_binary(data) do
    {:noreply, ingest_output(state, data)}
  end

  def handle_info({:term_data, _ref, data, :replay}, state) when is_binary(data) do
    {:noreply, ingest_replay(state, data)}
  end

  def handle_info({:term_data, _ref, data}, state) when is_binary(data) do
    {:noreply, ingest_output(state, data)}
  end

  def handle_info({:terminal_payload, :data, %{data: data, replay: true}}, state)
      when is_binary(data) do
    {:noreply, ingest_replay(state, data)}
  end

  def handle_info({:terminal_payload, :data, %{data: data}}, state) when is_binary(data) do
    {:noreply, ingest_output(state, data)}
  end

  # Coalesced output flush — drains the buffered iolist into the term in one
  # write, builds the frame here (off the LiveView process), and sends the
  # finished frame + the raw bytes to the LV.
  def handle_info(:flush_output, state) do
    {:noreply, flush_output(state)}
  end

  def handle_info({:terminal_payload, :exit, reason}, state) do
    send(state.parent, {:pty_exit, state.pane_id, reason})
    {:stop, :normal, state}
  end

  # Term query responses (e.g. cursor-position reports). Stay inside the
  # worker and write to *this* pane's PTY — no cross-pane bleed.
  def handle_info({:pty_write, data}, state) when is_binary(data) do
    unless ignored_terminal_response?(data) do
      theme = Terminals.active_terminal_theme(state.theme_bundle, state.terminal_scheme)
      data = Terminals.rewrite_terminal_pty_write(data, theme)
      write_backend(state, data)
    end

    {:noreply, state}
  end

  def handle_info({:terminal_scheme, scheme}, state) when scheme in [:dark, :light] do
    {:noreply, %{state | terminal_scheme: scheme}}
  end

  def handle_info({:terminal_preset, preset}, state) when is_binary(preset) do
    if Terminals.valid_terminal_theme_preset?(preset) do
      {:noreply,
       %{state | terminal_preset: preset, theme_bundle: Terminals.terminal_theme_bundle(preset)}}
    else
      {:noreply, state}
    end
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

  # Safety net: an app opened a synchronized update but hasn't closed it within
  # @sync_max_defer_ms. Force the held frame out so the pane never freezes.
  def handle_info(:sync_flush_timeout, state) do
    state = %{state | sync_timer?: false}

    if state.sync_active? do
      {:noreply, push_frame(%{state | sync_active?: false})}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Buffer the raw chunk for the coalesced flush. Both the term write/frame
  # AND the LV's `{:pty_data, ...}` byte-stream side channels (OSC52
  # clipboard, preview-URL detection) drain on the same @flush_interval_ms
  # cadence — sending pty_data per raw chunk used to flood the LV mailbox
  # under heavy output (one message per PTY write), queueing keystrokes and
  # clicks behind hundreds of regex scans. Iolists are cheap to extend in
  # head position; we reverse when draining.
  # Replay buffers are byte-offset cuts of a retained escape stream: they can
  # start mid-sequence and span output emitted at older grid sizes. Parsed on
  # top of existing grid content, those old absolute-positioned paints land at
  # wrong offsets and are never overwritten — the "tiled TUI" corruption seen
  # on reconnect. Reset the emulator to a blank grid, drop any buffered
  # pre-replay bytes (the replay tail supersedes them), and start the replay at
  # the first escape introducer so a leading partial sequence never smears
  # junk. The post-attach refresh-client heal (SessionOwner) then repaints the
  # true screen over anything the replay got wrong.
  defp ingest_replay(state, data) do
    if Process.alive?(state.term), do: Ghostty.Terminal.reset(state.term)
    state = %{state | out_buffer: [], last_cells: nil}
    ingest_output(state, replay_tail(data))
  end

  # Start a replayed escape stream at its first ESC so a byte-offset cut never
  # begins mid-sequence (stray CSI params would print as literal text).
  defp replay_tail(data) do
    case :binary.match(data, "\e") do
      {0, _} -> data
      {pos, _} -> binary_part(data, pos, byte_size(data) - pos)
      :nomatch -> data
    end
  end

  defp ingest_output(state, data) do
    state = %{state | out_buffer: [data | state.out_buffer]}

    if state.flush_scheduled? do
      state
    else
      Process.send_after(self(), :flush_output, @flush_interval_ms)
      %{state | flush_scheduled?: true}
    end
  end

  defp flush_output(state) do
    state = %{state | flush_scheduled?: false}

    case state.out_buffer do
      [] ->
        state

      chunks_rev ->
        data = Enum.reverse(chunks_rev)
        binary = IO.iodata_to_binary(data)
        state = %{state | out_buffer: []}

        # One coalesced binary per flush window for the LV side channels,
        # regardless of how many chunks the PTY produced. Coalescing also
        # makes OSC52/URL sequences split across chunk boundaries visible to
        # the LV's scanners. Sent before the term write so the side channels
        # keep flowing even when the term is gone.
        send(state.parent, {:pty_data, state.pane_id, binary})

        # Write + render here so the synchronous term GenServer.calls run on
        # this worker, never on the LiveView process. One write per frame
        # regardless of how many chunks were coalesced.
        if write_term(state.term, binary) do
          maybe_push_frame(state, binary)
        else
          # Term is gone/unresponsive; skip the frame. A later :pty_exit or
          # term restart drives recovery.
          state
        end
    end
  end

  # Gate the frame on DEC 2026 synchronized-output state. The term already has
  # the bytes (its grid is current); we only decide *when* to emit the frame.
  defp maybe_push_frame(state, binary) do
    cond do
      Terminals.terminal_sync_output_active_after?(binary, state.sync_active?) ->
        # Inside an open synchronized update: hold the frame back.
        schedule_sync_timeout(%{state | sync_active?: true})

      state.sync_active? ->
        # The update just closed: emit the now-complete frame.
        push_frame(%{state | sync_active?: false, sync_timer?: false})

      true ->
        push_frame(state)
    end
  end

  defp schedule_sync_timeout(%{sync_timer?: true} = state), do: state

  defp schedule_sync_timeout(state) do
    Process.send_after(self(), :sync_flush_timeout, @sync_max_defer_ms)
    %{state | sync_timer?: true}
  end

  defp write_term(term, data) do
    if is_pid(term) and Process.alive?(term) do
      Ghostty.Terminal.write(term, data)
      true
    else
      false
    end
  catch
    :exit, _ -> false
  end

  defp push_frame(state, opts \\ []) do
    force_full? = Keyword.get(opts, :force_full?, false) or is_nil(state.last_cells)
    {frame_seq, frame_epoch} = next_frame_position(state, force_full?)
    id = "ghostty-" <> state.pane_id

    case TerminalRender.frame_from_term(state.term, id,
           previous_cells: state.last_cells,
           force_full?: force_full?,
           frame_seq: frame_seq,
           frame_epoch: frame_epoch
         ) do
      {payload, cells} ->
        send(state.parent, {:pane_frame, state.pane_id, payload})
        %{state | last_cells: cells, frame_seq: frame_seq, frame_epoch: frame_epoch}

      nil ->
        state
    end
  end

  defp next_frame_position(state, true), do: {0, state.frame_epoch + 1}
  defp next_frame_position(state, false), do: {state.frame_seq + 1, state.frame_epoch}

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
    if Terminals.tmux_host_shell?() || Terminals.tmux_container_has_tmux?(cwd) do
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
    # and rollback while production uses the shared terminal session backend.
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
    new_session = fn opts ->
      ["new-session", "-A"] ++
        Terminals.terminal_shim_tmux_env_flags(opts) ++
        ["-s", tmux_session]
    end

    # Host-targeted invocations carry the server label (`-L …`) and config
    # (`-f …`) so they match TmuxRunner's management calls; container-wrapped
    # tmux runs on the workspace's own isolated server, so no label.
    host_base = fn -> Terminals.tmux_host_argv(new_session.([])) end
    container_base = fn -> ["tmux" | new_session.(include_path?: false)] end
    size = ["-x", to_string(cols), "-y", to_string(rows)]

    {tmux_invocation, env_opts} =
      cond do
        Terminals.tmux_host_shell?() ->
          {host_base.() ++ ["-c", cwd] ++ size ++ [wrapped_login_shell_command()], []}

        wraps_into_container?() ->
          # The tmux server may live inside the wrapped workspace environment,
          # but the pane itself should still be a login shell so PATH/profile
          # managed tools are available to the operator.
          {container_base.() ++ size ++ [wrapped_login_shell_command()], [include_path?: false]}

        true ->
          {host_base.() ++ ["-c", cwd] ++ size, []}
      end

    (["env", "TERM=xterm-256color", "COLORTERM=truecolor"] ++
       Terminals.terminal_shim_argv_env(env_opts) ++ tmux_invocation)
    |> then(fn argv ->
      if not Terminals.tmux_host_shell?() && Terminals.tmux_container_has_tmux?(cwd) do
        # Pass cwd so the wrapped `docker compose` pins --project-directory —
        # Ghostty.PTY can't set the process cwd, and compose otherwise can't
        # find the workspace project.
        DevIDE.WorkspaceSource.prepare_local_argv(argv, tty: true, cwd: cwd)
      else
        argv
      end
    end)
    |> Terminals.clean_terminal_argv()
  end

  # True when the configured WorkspaceSource wraps argv to run inside the
  # workspace container (e.g. `docker compose exec`). Used to decide whether the
  # host cwd is meaningful for the terminal's start directory.
  defp wraps_into_container? do
    DevIDE.WorkspaceSource.prepare_local_argv(["__cwd_probe__"]) != ["__cwd_probe__"]
  end

  defp wrapped_login_shell_command do
    Application.get_env(:dev_ide, :tmux_login_shell_command) ||
      System.get_env("DEV_IDE_TMUX_LOGIN_SHELL") ||
      "bash -l"
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

  # Only the session_owner backend coordinates multiple viewers on one shared
  # tmux/PTY, so it is the only backend that cares which viewer is focused. The
  # legacy per-tab backends own their own PTY and ignore the signal.
  defp active_backend(
         %{backend: :session_owner, pty: pid, terminal_module: terminal_module},
         active?
       )
       when is_pid(pid) do
    if Process.alive?(pid), do: terminal_module.owner_set_active(pid, active?)
  end

  defp active_backend(_state, _active?), do: :ok

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

  # Ghostty answers some terminal probes itself. When startup probes are replayed
  # from a prewarmed tmux client, forwarding those late answers back into tmux
  # can put literal capability text at the shell prompt.
  defp ignored_terminal_response?(data) do
    Regex.match?(@xtversion_response, data) or Regex.match?(@device_attrs_response, data)
  end
end
