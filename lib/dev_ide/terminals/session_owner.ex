defmodule DevIDE.Terminals.SessionOwner do
  @moduledoc """
  Per-session terminal owner process.

  Owns one logical session (shell/agent placeholder) and multiplexes
  backend output to all attached channel callers for that logical session.
  """

  use GenServer
  require Logger

  alias DevIDE.Terminals.{Attachment, CommandTracker, Session.Info, SessionEvents}
  alias DevIDE.Terminals.ScrollbackArchive
  alias DevIDE.Terminals.SessionRecovery
  alias DevIDE.Terminals.Telemetry
  alias DevIDE.Terminals.Theme
  alias DevIDE.Terminals.Tmux

  # Default replay buffer; overridable via Application env for the knob.
  # See `replay_buffer_limit/0`.
  @default_replay_buffer_bytes 32 * 1024

  # Debounce window for SessionEvents content broadcasts. Live output bumps
  # `gen` per backend chunk; the emit is trailing-edge debounced so a burst
  # collapses to one event carrying the burst's final generation. Consumers
  # are watchers/activity surfaces, not renderers — they need freshness, not
  # frame rate.
  @event_emit_interval_ms 25

  # Slow tick: re-assert tmux window size when an external client moved it
  # under `window-size manual`. Cheap — one display-message per interval.
  @tmux_drift_check_interval_ms 30_000

  # Minimum gap between resize-window tasks (coalesce still latest-wins).
  # Prevents flappy SIGWINCH storms that have crashed the tmux server.
  @tmux_resize_min_interval_ms 150

  # After term_exit, attempt to re-open the shell attachment this many times
  # before broadcasting exit and stopping the owner.
  @backend_recover_max 5
  @backend_recover_backoff_ms 400

  # Bound synchronous tmux window_size on attach/drift so a wedged adapter
  # cannot block the owner mailbox indefinitely.
  @default_tmux_window_size_timeout_ms 2_000

  # Query-response classification (see `classify_query_response/1`). One tmux
  # query fans out to N viewer emulators; answers of the same class arriving
  # within this window are duplicates of one underlying query, not new answers.
  @query_response_dedupe_ms 100

  @cpr_response ~r/\A\e\[\??\d+;\d+R/
  @da_response ~r/\A\e\[(?:\?|>)[0-9;]*c/
  @decrpm_response ~r/\A\e\[\?[0-9;]*\$y/
  @kitty_response ~r/\A\e\[\?[0-9;]*u/
  @osc_color_response ~r/\A\e\](?:10|11|12);/
  @osc_palette_response ~r/\A\e\]4;/
  @xtversion_response ~r/\A\eP>\|/
  @theme_report_response ~r/\A\e\[\?997;[12]n/

  @doc """
  Returns the configured replay buffer byte limit for owner (used for
  reconnect UX). Defaults to 32 KiB. Override via:

      config :dev_ide, :terminal_replay_buffer_bytes, 64 * 1024

  (or runtime env). All behavior, truncation, and tests remain identical
  at the default.
  """
  def replay_buffer_limit do
    Application.get_env(:dev_ide, :terminal_replay_buffer_bytes, @default_replay_buffer_bytes)
  end

  defstruct [
    :workspace_id,
    :info,
    :workspace_key,
    :loc,
    :host_id,
    :attachment,
    :replay_buffer,
    :replay_buffer_limit,
    # Monotonic content generation: +1 per live (non-replay) backend chunk.
    # Stamped on data payloads and SessionEvents broadcasts so consumers can
    # order and compare what they've seen. Never reset while the owner lives.
    gen: 0,
    command_tracker: nil,
    event_emit_scheduled?: false,
    raw_subscribers: MapSet.new(),
    subscribers: %{},
    subscriber_refs: %{},
    subscriber_to_ref: %{},
    raw_subscriber_last_seen: %{},
    # Last terminal size each raw viewer reported (%{subscriber_pid => {cols, rows}}),
    # which viewers are currently active/visible+focused
    # (%{subscriber_pid => {active?, activation_seq}}), and the size we actually
    # applied to the shared PTY/tmux. See the focused-viewer policy above
    # `record_subscriber_size/3`.
    subscriber_sizes: %{},
    subscriber_active: %{},
    applied_size: nil,
    # When each subscriber last reported a size (monotonic ms). Feeds the
    # bootstrap-flap detector in `record_subscriber_size/4`.
    subscriber_size_at: %{},
    # Single-flight tmux resize: `tmux_resize` is %{ref: task_ref, size: size}
    # while a resize-window task is in flight; `tmux_resize_pending` holds the
    # latest size requested meanwhile. See `maybe_resize_tmux_window/3`.
    tmux_resize: nil,
    tmux_resize_pending: nil,
    # Monotonic ms of the last resize-window task start (rate-limit).
    tmux_resize_last_ms: 0,
    tmux_drift_timer: nil,
    # Consecutive drift-check re-asserts without ever finding the window at
    # applied_size. A sustained streak means another writer is fighting us
    # (stale draining instance, duplicate owner, external client).
    tmux_drift_streak: 0,
    # Backend reattach after term_exit (shell owners with live viewers).
    backend_recover_attempts: 0,
    backend_recover_timer: nil,
    cursor: nil,
    # Session-level terminal theme used to rewrite OSC color query responses
    # (last-writer-wins across viewers via `set_theme/3`). `theme` caches the
    # lazily built active `Theme` struct and is invalidated on set_theme.
    theme_scheme: DevIDE.Terminals.Theme.default_scheme(),
    theme_preset: DevIDE.Terminals.Theme.default_preset_id(),
    theme: nil,
    # `{class, monotonic_ms}` of the last query response forwarded to the PTY,
    # used to collapse same-class duplicates arriving in a short window.
    last_response: nil
  ]

  def owner_key(%Info{kind: :shell} = info),
    do: {:terminal_owner, :shell, to_string(info.workspace_id), to_string(info.sid || "")}

  def owner_key(%Info{kind: :agent} = info),
    do: {:terminal_owner, :agent, to_string(info.runner_id || info.id || "")}

  def owner_key(info), do: {:terminal_owner, :session, to_string(info.id || "")}

  def start_link({workspace_id, info}) do
    GenServer.start_link(__MODULE__, {workspace_id, info},
      name: {:via, Registry, {DevIDE.Terminals.Registry, owner_key(info)}}
    )
  end

  def child_spec({workspace_id, info}) do
    %{
      id: {__MODULE__, workspace_id, info.id},
      start: {__MODULE__, :start_link, [{workspace_id, info}]},
      restart: :temporary
    }
  end

  def attach(workspace_id, info, opts) when is_binary(workspace_id) do
    mode = Keyword.fetch!(opts, :mode)

    case ensure_started(workspace_id, info) do
      {:ok, pid} ->
        case GenServer.call(pid, {:attach, self(), mode, opts}) do
          {:ok, payload} -> {:ok, pid, payload}
          {:error, reason} -> {:error, reason}
        end

      {:error, {:already_started, pid}} ->
        case call_attach_direct(pid, self(), mode, opts) do
          {:ok, payload} -> {:ok, pid, payload}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def detach(owner_pid, subscriber) when is_pid(owner_pid) do
    GenServer.call(owner_pid, {:detach, subscriber})
  end

  def input(owner_pid, data) when is_pid(owner_pid) and is_binary(data) do
    GenServer.cast(owner_pid, {:input, data})
    :ok
  end

  @doc """
  Forward a terminal query response generated by the calling viewer's emulator
  (DSR cursor reports, OSC 10/11/12/4 color replies, ...). Every attached
  viewer answers every query, so the owner gates these: only the current
  responder's answer reaches the PTY, rewritten with the SESSION theme. See
  the single-responder policy above `current_responder/1`. Self-tagging
  mirrors `resize/3`: the calling PaneWorker pid is the monitored subscriber.
  """
  def query_response(owner_pid, data) when is_pid(owner_pid) and is_binary(data) do
    GenServer.cast(owner_pid, {:query_response, self(), data})
    :ok
  end

  @doc """
  Sets the session-level terminal theme used to rewrite OSC color query
  responses. Last writer wins across viewers, matching the tmux session-env
  theme push semantics.
  """
  def set_theme(owner_pid, scheme, preset)
      when is_pid(owner_pid) and scheme in [:dark, :light] and is_binary(preset) do
    GenServer.cast(owner_pid, {:set_theme, scheme, preset})
    :ok
  end

  def resize(owner_pid, cols, rows)
      when is_pid(owner_pid) and is_integer(cols) and is_integer(rows) do
    # Tag the resize with the calling viewer (the PaneWorker pid, which is also
    # the monitored subscriber) so the owner can size the shared PTY to the
    # FOCUSED viewer rather than letting the last writer win. See the
    # focused-viewer policy above `record_subscriber_size/3`.
    GenServer.cast(owner_pid, {:resize, self(), cols, rows})
    :ok
  end

  @doc """
  Report whether the calling viewer (PaneWorker pid) is currently the active,
  visible, focused attachment. The owner sizes the shared PTY/tmux to the
  most-recently-active viewer; hidden/background viewers no longer drag the
  shared size down. See the focused-viewer policy above `record_subscriber_size/3`.
  """
  def set_active(owner_pid, active?)
      when is_pid(owner_pid) and is_boolean(active?) do
    GenServer.cast(owner_pid, {:viewer_active, self(), active?})
    :ok
  end

  @doc """
  Cheap subscriber count for a live owner pid. Returns map_size(subscribers).
  Intended for LiveView/channel presence badges ("N viewers on this shell")
  and dashboard UX.
  """
  def subscriber_count(owner_pid) when is_pid(owner_pid) do
    GenServer.call(owner_pid, :subscriber_count)
  end

  @doc """
  True when a live `:shell` SessionOwner still backs `tmux_session`.

  Used by `TmuxJanitor` so opt-in idle GC cannot destroy durable workspace
  shells after the last LiveView subscriber detaches.
  """
  @spec durable_shell_session?(String.t()) :: boolean()
  def durable_shell_session?(tmux_session) when is_binary(tmux_session) do
    Enum.any?(Telemetry.shell_owner_pids(), fn pid ->
      tmux_session == tmux_session_name(pid)
    end)
  end

  defp tmux_session_name(pid) do
    GenServer.call(pid, :tmux_session_name)
  catch
    :exit, _ -> nil
  end

  @impl true
  def init({workspace_id, info}) do
    Logger.info("terminal owner started",
      workspace_id: workspace_id,
      kind: info.kind,
      id: info.id
    )

    :telemetry.execute([:dev_ide, :terminals, :owner, :started], %{count: 1}, %{kind: info.kind})
    Telemetry.owner_started(self(), info.kind, owner_key(info))

    {:ok,
     %__MODULE__{
       workspace_id: workspace_id,
       info: info,
       subscribers: %{},
       subscriber_refs: %{},
       subscriber_to_ref: %{},
       replay_buffer: <<>>,
       replay_buffer_limit: replay_buffer_limit(),
       command_tracker: CommandTracker.new(workspace_id, info.sid),
       raw_subscriber_last_seen: %{},
       cursor: nil
     }}
  end

  @impl true
  def handle_call({:attach, subscriber, mode, opts}, _from, state) do
    previous_state = state
    reuse? = Map.has_key?(state.subscribers, subscriber)
    previous_mode = Map.get(state.subscribers, subscriber)
    fresh? = not reuse?

    state =
      if reuse? do
        Logger.debug("terminal owner attach reuse",
          subscriber: subscriber,
          mode: mode,
          kind: state.info.kind
        )

        :telemetry.execute([:dev_ide, :terminals, :owner, :attach], %{count: 1}, %{
          mode: mode,
          reuse: true,
          kind: state.info.kind
        })

        state
        |> update_in([Access.key!(:subscribers)], &Map.put(&1, subscriber, mode))
      else
        ref = Process.monitor(subscriber)

        Logger.info("terminal owner attached",
          subscriber: subscriber,
          mode: mode,
          kind: state.info.kind
        )

        :telemetry.execute([:dev_ide, :terminals, :owner, :attach], %{count: 1}, %{
          mode: mode,
          reuse: false,
          kind: state.info.kind
        })

        state
        |> update_in([Access.key!(:subscribers)], &Map.put(&1, subscriber, mode))
        |> update_in([Access.key!(:subscriber_refs)], &Map.put(&1, ref, subscriber))
        |> update_in([Access.key!(:subscriber_to_ref)], &Map.put(&1, subscriber, ref))
      end

    state = adjust_raw_subscribers(state, subscriber, previous_mode, mode)

    state =
      state
      |> bind_attachment_context(:workspace_key, Keyword.get(opts, :workspace_key))
      |> bind_attachment_context(:loc, Keyword.get(opts, :loc))
      |> bind_attachment_context(:host_id, Keyword.get(opts, :host_id))

    case ensure_attachment(state, subscriber, mode, opts) do
      {:ok, next_state, payload} ->
        next_state =
          next_state
          |> assert_tmux_window_size()
          |> schedule_tmux_drift_check()

        if next_state.applied_size do
          {cols, rows} = next_state.applied_size
          broadcast_owner_size(next_state.subscribers, cols, rows)
        end

        maybe_set_owner_subscriber_gauge(previous_state, next_state)
        {:reply, {:ok, payload}, next_state}

      {:error, reason} ->
        Logger.warning("terminal owner attach error", reason: inspect(reason), mode: mode)

        :telemetry.execute([:dev_ide, :terminals, :owner, :attach_error], %{count: 1}, %{
          reason: inspect(reason),
          mode: mode
        })

        reply_state = if fresh?, do: prune_subscriber(state, subscriber), else: state
        maybe_set_owner_subscriber_gauge(previous_state, reply_state)
        {:reply, {:error, reason}, reply_state}
    end
  end

  @impl true
  def handle_call({:detach, subscriber}, _from, state) do
    Logger.debug("terminal owner detach", subscriber: subscriber, kind: state.info.kind)

    :telemetry.execute([:dev_ide, :terminals, :owner, :detach], %{count: 1}, %{
      kind: state.info.kind
    })

    next_state = prune_subscriber(state, subscriber)
    maybe_set_owner_subscriber_gauge(state, next_state)

    if should_stop?(next_state) do
      {:stop, :normal, :ok, next_state}
    else
      {:reply, :ok, next_state}
    end
  end

  @impl true
  # Returns map_size of the subscribers map. Matches the documented "cheap"
  # public contract of subscriber_count/1 and the
  # Terminals.owner_subscriber_count/1 delegate (used by presence/UX/telemetry).
  def handle_call(:subscriber_count, _from, state) do
    {:reply, map_size(state.subscribers), state}
  end

  def handle_call(:tmux_session_name, _from, %{workspace_key: key, info: %{sid: sid}} = state) do
    {:reply, tmux_session_name_for(key, sid), state}
  end

  def handle_call({:resize, cols, rows}, _from, state)
      when is_integer(cols) and is_integer(rows) do
    {:reply, :ok, direct_resize(state, cols, rows)}
  end

  def handle_call({:write, data}, _from, state) when is_binary(data) do
    send_input_to_attachment(state, data)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:input, data}, state) do
    send_input_to_attachment(state, data)

    {:noreply, state}
  end

  # Viewer-tagged terminal query response: gate through the single-responder
  # policy (see `current_responder/1`) and the same-class duplicate window,
  # then rewrite OSC colors with the session theme before writing to the PTY.
  def handle_cast({:query_response, from, data}, state)
      when is_pid(from) and is_binary(data) do
    {:noreply, handle_query_response(state, from, data)}
  end

  def handle_cast({:set_theme, scheme, preset}, state)
      when scheme in [:dark, :light] and is_binary(preset) do
    changed? = state.theme_scheme != scheme or state.theme_preset != preset

    # Drop the cached struct; it is rebuilt lazily on the next query response.
    state = %{state | theme_scheme: scheme, theme_preset: preset, theme: nil}

    state =
      if changed? and tmux_tracks_client_colors?() do
        report_client_colors(state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  # Viewer-tagged resize: record this viewer's size and drive the shared PTY/tmux
  # to the focused viewport. Used by `resize/3`.
  def handle_cast({:resize, subscriber, cols, rows}, state)
      when is_pid(subscriber) and is_integer(cols) and is_integer(rows) do
    {:noreply, record_subscriber_size(state, subscriber, cols, rows)}
  end

  # Viewer-tagged focus/visibility report: record this viewer's active state and
  # recompute the authoritative size. Used by `set_active/2`.
  def handle_cast({:viewer_active, subscriber, active?}, state)
      when is_pid(subscriber) and is_boolean(active?) do
    {:noreply, record_subscriber_active(state, subscriber, active?)}
  end

  # Legacy untagged resize (direct callers / tests): applies verbatim, no clamp.
  def handle_cast({:resize, cols, rows}, state) do
    {:noreply, direct_resize(state, cols, rows)}
  end

  @impl true
  def handle_info({:term_data, _ref, data, :replay}, state) when is_binary(data) do
    next_state = handle_term_data(state, data, true)
    {:noreply, next_state}
  end

  @impl true
  def handle_info({:term_data, _ref, data}, state) when is_binary(data) do
    next_state = handle_term_data(state, data, false)
    {:noreply, next_state}
  end

  @impl true
  def handle_info({:term_data, data}, state) when is_binary(data) do
    next_state = handle_term_data(state, data, false)
    {:noreply, next_state}
  end

  @impl true
  def handle_info({:term_exit, reason}, state) do
    handle_term_exit(state, reason)
  end

  @impl true
  def handle_info({:term_exit, _ref, reason}, state) do
    handle_term_exit(state, reason)
  end

  @impl true
  def handle_info(:backend_recover, state) do
    state = %{state | backend_recover_timer: nil}

    case attempt_backend_recover(state) do
      {:stop, reason, next} -> {:stop, reason, next}
      next -> {:noreply, next}
    end
  end

  @impl true
  def handle_info(:tmux_resize_rate_limit, state) do
    case state.tmux_resize_pending do
      nil ->
        {:noreply, state}

      size when state.tmux_resize == nil ->
        {:noreply, start_tmux_resize(%{state | tmux_resize_pending: nil}, size)}

      _pending ->
        # Task still in flight; completion path will run pending.
        {:noreply, state}
    end
  end

  # Serialized tmux resize task finished (async_nolink reply). Run the latest
  # size queued while it was in flight, if any.
  @impl true
  def handle_info({ref, _result}, %{tmux_resize: %{ref: ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, run_pending_tmux_resize(%{state | tmux_resize: nil})}
  end

  # The resize task crashed before replying. Clear the single-flight slot so
  # the next size change (or the queued one) can still run — best-effort, same
  # as the old fire-and-forget behavior on failure.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{tmux_resize: %{ref: ref}} = state) do
    {:noreply, run_pending_tmux_resize(%{state | tmux_resize: nil})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    next_state = prune_subscriber_ref(state, ref)
    maybe_set_owner_subscriber_gauge(state, next_state)

    if should_stop?(next_state) do
      {:stop, :normal, next_state}
    else
      {:noreply, next_state}
    end
  end

  # Debounced content-event emit (see `bump_content_gen/1`). Trailing-edge:
  # the event carries the latest generation at fire time, so subscribers see
  # one event per burst covering everything the burst produced.
  @impl true
  def handle_info(:emit_session_event, state) do
    SessionEvents.broadcast_output(state.workspace_id, state.info.sid, state.gen)
    {:noreply, %{state | event_emit_scheduled?: false}}
  end

  @impl true
  def handle_info(:tmux_drift_check, state) do
    state =
      state
      |> Map.put(:tmux_drift_timer, nil)
      |> maybe_recover_missing_tmux_session()
      |> assert_tmux_window_size()
      |> schedule_tmux_drift_check()

    {:noreply, state}
  end

  @impl true
  def handle_info(_, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = cancel_tmux_drift_timer(state)
    _ = cancel_backend_recover_timer(state)
    Telemetry.owner_stopped(self())

    if state.attachment != nil do
      Telemetry.owner_attachment_closed()
    end

    if state.attachment do
      Attachment.close(state.attachment)
    end

    :ok
  end

  # Shell owners with live viewers re-open the Session attachment instead of
  # dying — tmux -A recreates an empty session if the server wiped, and
  # ScrollbackArchive reseeds history when available. Agent placeholders and
  # owners with no subscribers keep the legacy broadcast+stop path.
  defp handle_term_exit(%{info: %Info{kind: :shell}} = state, reason) do
    if map_size(state.subscribers) > 0 do
      Logger.warning(
        "terminal owner backend exited; scheduling recover reason=#{inspect(reason)} kind=shell"
      )

      state =
        state
        |> clear_dead_attachment()
        |> schedule_backend_recover()

      {:noreply, state}
    else
      broadcast_exit(state.subscribers, reason)
      {:stop, :normal, state}
    end
  end

  defp handle_term_exit(state, reason) do
    broadcast_exit(state.subscribers, reason)
    {:stop, :normal, state}
  end

  defp clear_dead_attachment(%{attachment: nil} = state), do: state

  defp clear_dead_attachment(state) do
    Telemetry.owner_attachment_closed()
    # Session is already dead; close is best-effort.
    try do
      Attachment.close(state.attachment)
    catch
      :exit, _ -> :ok
    end

    %{state | attachment: nil}
  end

  defp schedule_backend_recover(state) do
    state = cancel_backend_recover_timer(state)
    ref = Process.send_after(self(), :backend_recover, @backend_recover_backoff_ms)
    %{state | backend_recover_timer: ref}
  end

  defp cancel_backend_recover_timer(%{backend_recover_timer: ref} = state)
       when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | backend_recover_timer: nil}
  end

  defp cancel_backend_recover_timer(state), do: state

  defp attempt_backend_recover(state) do
    attempts = state.backend_recover_attempts + 1

    if attempts > @backend_recover_max do
      Logger.error(
        "terminal owner backend recover exhausted attempts=#{attempts}; stopping owner"
      )

      broadcast_exit(state.subscribers, :backend_recover_failed)
      {:stop, :normal, %{state | backend_recover_attempts: attempts}}
    else
      session = tmux_session_for(state)
      # Detect wipe *before* open_attachment creates a fresh session.
      missing? = is_binary(session) and not Tmux.session_exists?(session)
      history_restored? = is_binary(session) and ScrollbackArchive.present?(session)

      case open_attachment(state, []) do
        {:ok, attachment} ->
          Logger.info(
            "terminal owner backend recovered attempt=#{attempts} session=#{session} missing=#{missing?}"
          )

          Telemetry.owner_attachment_opened()

          :telemetry.execute(
            [:dev_ide, :terminals, :owner, :backend_recovered],
            %{count: 1},
            %{attempt: attempts, missing: missing?}
          )

          # Only notify when the tmux session was gone (server wipe / kill).
          # Client-only death that reattaches an existing session stays silent.
          if missing? do
            SessionRecovery.notify_session_recreated(
              tmux_session: session,
              workspace_id: state.workspace_id,
              sid: state.info.sid,
              reason: :session_missing_on_recover,
              history_restored?: history_restored?,
              template_id: SessionRecovery.recovery_template(state.workspace_id)
            )
          end

          s2 = %{
            state
            | attachment: attachment,
              backend_recover_attempts: 0
          }

          s2 =
            if tmux_tracks_client_colors?() do
              report_client_colors(s2)
            else
              s2
            end

          # Replay retained Session buffer, then re-assert the last known
          # viewer size so a fresh new-session is not left at bootstrap geometry.
          s2
          |> replay_all_raw_subscribers()
          |> reassert_size_after_recover()

        {:error, reason} ->
          Logger.warning(
            "terminal owner backend recover failed attempt=#{attempts} reason=#{inspect(reason)}"
          )

          state
          |> Map.put(:backend_recover_attempts, attempts)
          |> schedule_backend_recover()
      end
    end
  end

  defp reassert_size_after_recover(%{applied_size: {cols, rows}} = state)
       when is_integer(cols) and is_integer(rows) do
    state
    |> maybe_resize_tmux_window(cols, rows)
    |> then(fn s ->
      if s.attachment do
        _ = Attachment.resize(s.attachment, cols, rows)
      end

      s
    end)
    |> assert_tmux_window_size()
  end

  defp reassert_size_after_recover(state), do: assert_tmux_window_size(state)

  defp replay_all_raw_subscribers(state) do
    Enum.reduce(MapSet.to_list(state.raw_subscribers), state, fn pid, acc ->
      replay_to_subscriber(acc, pid)
    end)
  end

  defp tmux_session_for(%{workspace_key: key, info: %{sid: sid}})
       when is_binary(key) and is_binary(sid),
       do: Tmux.session_name(key, sid)

  defp tmux_session_for(_), do: nil

  # Drift tick: if the tmux session vanished under us (server wipe) while the
  # PTY client is still somehow attached, force a backend recover.
  defp maybe_recover_missing_tmux_session(
         %{workspace_key: key, info: %{kind: :shell, sid: sid}, attachment: att} = state
       )
       when is_binary(key) and is_binary(sid) and not is_nil(att) do
    session = Tmux.session_name(key, sid)

    if Tmux.session_exists?(session) do
      state
    else
      Logger.warning("tmux session missing under live owner; recovering session=#{session}")

      # Notify is deferred until successful recover (UUID + history flags
      # accurate). Dedupe covers any race with term_exit recover.
      state
      |> clear_dead_attachment()
      |> schedule_backend_recover()
    end
  end

  defp maybe_recover_missing_tmux_session(state), do: state

  # Attachment context binds once per owner. A later attach without these opts
  # (e.g. a re-join that omits :loc) or with a conflicting value must not
  # clobber the context the live attachment was opened with.
  defp bind_attachment_context(state, _key, nil), do: state

  defp bind_attachment_context(state, key, value) do
    case Map.fetch!(state, key) do
      nil ->
        Map.put(state, key, value)

      ^value ->
        state

      existing ->
        Logger.warning(
          "terminal owner attach context conflict; keeping existing " <>
            "#{key}=#{inspect(existing)} over #{inspect(value)}",
          kind: state.info.kind
        )

        :telemetry.execute(
          [:dev_ide, :terminals, :owner, :binding_conflict],
          %{count: 1},
          %{key: key, kind: state.info.kind}
        )

        state
    end
  end

  defp ensure_started(workspace_id, info) do
    key = owner_key(info)

    case Registry.lookup(DevIDE.Terminals.Registry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {__MODULE__, {workspace_id, info}}

        DynamicSupervisor.start_child(DevIDE.Terminals.Supervisor, spec)
    end
  end

  defp call_attach_direct(pid, subscriber, mode, opts) do
    GenServer.call(pid, {:attach, subscriber, mode, opts})
  end

  defp resize_attachment(state, cols, rows) do
    if state.attachment do
      Attachment.resize(state.attachment, cols, rows)
    end

    state
  end

  # --- Focused-viewer size policy --------------------------------------------
  #
  # One SessionOwner owns a single PTY + tmux window at a single size, but every
  # connected viewer fits and renders its own grid to its own viewport. A PTY has
  # exactly ONE winsize, so when viewers differ in size, one must win — you cannot
  # show the same tmux pane at two widths without one viewer's grid reflowing.
  #
  # History: letting each refit resize the shared PTY to *its* size
  # (last-writer-wins) made two differently-sized viewers ping-pong the PTY, so
  # tmux laid the TUI out for the wrong width on the other grid — the overlapping,
  # interleaved redraws operators saw. The first fix clamped to the SMALLEST
  # viewport (no overlap, every grid >= content), but that let a small or
  # backgrounded viewer (a phone, a hidden tab, a passive broadcast viewer) shrink
  # the primary user's full-width terminal into a narrow column with a blank
  # gutter — the more common, more visible failure.
  #
  # Policy now: size the shared PTY/tmux to the **most-recently-active** viewer
  # (visible AND window-focused, reported via `set_active/2`). The viewer the
  # human is actually driving always renders correctly; hidden/background and
  # passive viewers never drag the size down. When NO viewer is active (bootstrap
  # before the first focus report, or every viewer backgrounded) we fall back to
  # the LARGEST requested size, so the terminal is usable and never stuck at a
  # stale small viewer's width. A single viewer therefore always wins its own size.
  # The client bootstraps its grid from the component's dataset defaults
  # before any fit measurement. Every "narrow column" incident so far was a
  # viewer reporting this bootstrap size right after a real fitted size
  # (a stale deferred "ready" clobbering the fit — see PR #148); a genuine
  # 80x24 viewport arriving within the window is possible but rare enough
  # that a warning breadcrumb is cheap insurance.
  @bootstrap_default_size {80, 24}
  @size_flap_window_ms 2_000

  defp record_subscriber_size(state, subscriber, cols, rows) do
    detect_bootstrap_flap(state, subscriber, {cols, rows})

    sizes = Map.put(state.subscriber_sizes, subscriber, {cols, rows})
    stamps = Map.put(state.subscriber_size_at, subscriber, now_ms())

    apply_authoritative_size(%{state | subscriber_sizes: sizes, subscriber_size_at: stamps})
  end

  defp detect_bootstrap_flap(state, subscriber, @bootstrap_default_size = size) do
    with {cols, rows} = prev when prev != size <- state.subscriber_sizes[subscriber],
         at when is_integer(at) <- state.subscriber_size_at[subscriber],
         elapsed when elapsed < @size_flap_window_ms <- now_ms() - at do
      Logger.warning(
        "viewer size flapped #{cols}x#{rows} -> 80x24 within #{elapsed}ms — " <>
          "looks like a stale bootstrap-default report clobbering the fitted size",
        kind: state.info.kind
      )

      :telemetry.execute(
        [:dev_ide, :terminals, :owner, :size_flap],
        %{elapsed_ms: elapsed},
        %{kind: state.info.kind, from: prev, to: size}
      )
    else
      _ -> :ok
    end
  end

  defp detect_bootstrap_flap(_state, _subscriber, _size), do: :ok

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp record_subscriber_active(state, subscriber, true) do
    # `unique_integer([:monotonic])` is strictly increasing, so the newest
    # activation always wins the recency tiebreak with no clock-resolution races.
    entry = {true, System.unique_integer([:monotonic])}
    apply_authoritative_size(put_in(state.subscriber_active[subscriber], entry))
  end

  defp record_subscriber_active(state, subscriber, false) do
    apply_authoritative_size(put_in(state.subscriber_active[subscriber], {false, 0}))
  end

  # A viewer left: drop its size and active flag, then recompute. When the
  # focused (or largest fallback) viewer leaves, the size recomputes to the next
  # winner so remaining viewers regain control.
  defp forget_subscriber_view(state, subscriber) do
    state = %{
      state
      | subscriber_sizes: Map.delete(state.subscriber_sizes, subscriber),
        subscriber_size_at: Map.delete(state.subscriber_size_at, subscriber),
        subscriber_active: Map.delete(state.subscriber_active, subscriber)
    }

    apply_authoritative_size(state)
  end

  # Untagged resize (Ghostty.PTY-shaped callers, tests). While any viewer has
  # reported a size, the focused-viewer policy owns the shared PTY size: ignore
  # the request instead of letting a direct caller condense every viewer, and
  # re-assert the policy in case applied_size drifted. Only with no viewer
  # sizes on record (bootstrap, tests) is the request applied verbatim —
  # recorded as applied_size so a later policy recompute can still correct it
  # (a stale applied_size previously made the rogue size stick: the recompute
  # saw "no change" and never resized back).
  defp direct_resize(state, cols, rows) do
    case authoritative_size(state) do
      nil ->
        %{resize_attachment(state, cols, rows) | applied_size: {cols, rows}}

      _policy_owned ->
        apply_authoritative_size(state)
    end
  end

  defp apply_authoritative_size(state) do
    case authoritative_size(state) do
      nil ->
        state

      {size, _reason} when size == state.applied_size ->
        state

      {{cols, rows} = size, reason} ->
        state = resize_attachment(state, cols, rows)
        state = maybe_resize_tmux_window(state, cols, rows)
        emit_size_change(state, size, reason)

        %{state | applied_size: size}
        |> schedule_tmux_drift_check()
    end
  end

  # Returns `{ {cols, rows}, reason }` or nil. `reason` is `:focused` (a viewer
  # is actively driving) or `:largest_fallback` (nobody focused).
  defp authoritative_size(state) do
    case Map.values(state.subscriber_sizes) do
      [] ->
        nil

      all_sizes ->
        case active_sized_viewers(state) do
          [] -> {largest_size(all_sizes), :largest_fallback}
          actives -> {actives |> Enum.max_by(fn {seq, _size} -> seq end) |> elem(1), :focused}
        end
    end
  end

  # Active viewers (visible+focused) that have also reported a size, as
  # {activation_seq, {cols, rows}}. A viewer that is active but hasn't reported a
  # size yet is excluded until its size arrives (transient on a fresh attach).
  defp active_sized_viewers(state) do
    for {subscriber, {true, seq}} <- state.subscriber_active,
        size = Map.get(state.subscriber_sizes, subscriber),
        not is_nil(size),
        do: {seq, size}
  end

  # No viewer is focused: pick the LARGEST viewport by area, so the shared grid is
  # a real shape some viewer actually requested rather than an independent per-axis
  # max (which could synthesize a {cols, rows} nobody asked for).
  defp largest_size(sizes) do
    Enum.max_by(sizes, fn {cols, rows} -> {cols * rows, cols} end)
  end

  # Observability: this size policy has been a recurring, hard-to-diagnose source
  # of "my terminal is a narrow column" reports (each one debugged from a
  # screenshot). Emit a breadcrumb whenever the shared size actually changes so
  # the next occurrence is visible in logs/telemetry — including how many viewers
  # are attached/active and why this size won.
  defp emit_size_change(state, {cols, rows}, reason) do
    active_count = Enum.count(state.subscriber_active, fn {_sub, {active?, _seq}} -> active? end)
    viewers = map_size(state.subscriber_sizes)

    # Info, not debug: prod runs at info level, and every recurrence of the
    # "narrow column" class has had to be reconstructed from a screenshot
    # because this breadcrumb never reached the journal.
    Logger.info(
      "terminal owner size -> #{cols}x#{rows} (#{reason}); viewers=#{viewers} active=#{active_count}",
      kind: state.info.kind
    )

    :telemetry.execute(
      [:dev_ide, :terminals, :owner, :size_changed],
      %{cols: cols, rows: rows, viewers: viewers, active_viewers: active_count},
      %{kind: state.info.kind, reason: reason}
    )

    broadcast_owner_size(state.subscribers, cols, rows)
  end

  defp broadcast_owner_size(subscribers, cols, rows) do
    for {pid, _mode} <- subscribers do
      send(pid, {:terminal_owner_size, cols, rows})
    end

    :ok
  end

  # Best-effort: keep tmux's window size in lockstep with the authoritative PTY
  # size. Under `window-size manual` (see TmuxCtl.Client.apply_defaults/1)
  # SessionOwner is the sole writer — explicit resize-window is how viewer
  # resizes reach tmux. Runs off-process so a slow tmux subprocess never
  # blocks the owner mailbox (live term_data fan-out). Derives the same session
  # name the PaneWorker attached with. Skipped when the owner has no workspace
  # key bound (non-shell owners never reach here).
  #
  # SINGLE-FLIGHT, latest-wins: at most one resize task runs; sizes arriving
  # meanwhile coalesce into `tmux_resize_pending` and run when it completes.
  # Each task ends with a refresh-client heal so tmux repaints the full screen
  # at the settled size, converging any grid that diverged during the transition.
  # `assert_tmux_window_size/1` re-asserts on attach and on a slow tick when
  # something external moved the window anyway.
  defp maybe_resize_tmux_window(%{workspace_key: key, info: %{sid: sid}} = state, cols, rows)
       when is_binary(key) and is_binary(sid) do
    size = {cols, rows}

    case state.tmux_resize do
      nil -> start_tmux_resize(state, size)
      %{size: ^size} -> %{state | tmux_resize_pending: nil}
      _in_flight -> %{state | tmux_resize_pending: size}
    end
  end

  defp maybe_resize_tmux_window(state, _cols, _rows), do: state

  defp start_tmux_resize(%{workspace_key: key, info: %{sid: sid}} = state, {cols, rows} = size) do
    now = System.monotonic_time(:millisecond)
    last = state.tmux_resize_last_ms || 0
    elapsed = now - last

    # Rate-limit resize-window storms; keep latest size pending.
    if elapsed < @tmux_resize_min_interval_ms and last > 0 do
      delay = @tmux_resize_min_interval_ms - elapsed
      Process.send_after(self(), :tmux_resize_rate_limit, delay)
      %{state | tmux_resize_pending: size}
    else
      do_start_tmux_resize(state, key, sid, cols, rows, size, now)
    end
  end

  defp do_start_tmux_resize(state, key, sid, cols, rows, size, now) do
    # A draining instance must not write to shared tmux state: its owners can
    # outlive the deploy handoff for as long as a stale browser tab holds a
    # connection (up to the drain hard-timeout), and the replacement instance's
    # owners are already asserting the live viewers' sizes. Both writing means
    # the two releases ping-pong `resize-window` against each other every drift
    # tick — the operator sees the window snap between sizes twice a minute.
    case DevIDE.Deployment.Drain.guard_shared_write(fn ->
           session = Tmux.session_name(key, sid)
           # Resolve inside the owner (not the task) so test adapter swaps are stable.
           tmux = DevIDE.Terminals.tmux_adapter()

           task =
             Task.Supervisor.async_nolink(DevIDE.TaskSupervisor, fn ->
               _ = tmux.resize_window(session, cols, rows)
               _ = tmux.refresh_client(session)
               :ok
             end)

           %{ref: task.ref, size: size}
         end) do
      :noop ->
        state

      resize ->
        %{state | tmux_resize: resize, tmux_resize_last_ms: now}
    end
  end

  @current_socket "/run/devide/current.sock"

  # True when a newer instance owns the shared traffic socket — `current.sock`
  # no longer resolves to ours. A superseded instance that never received (or
  # lost) its drain signal is not `draining?`, yet its SessionOwners share the
  # same tmux sessions as the live instance; if it keeps re-asserting window
  # sizes it drift-fights the live owner (the zombie-canary bug). Standing down
  # here is defense in depth behind the deploy's drain/stop of old instances.
  #
  # Conservative by construction: only true when we positively have our own
  # managed socket AND `current.sock` resolves to a DIFFERENT one. Dev/test and
  # the legacy service (no DEVIDE_HTTP_SOCKET) read as not-superseded, as does a
  # brand-new instance before the deploy swaps `current.sock` to it (it is
  # legitimately not yet the owner). Reads the env directly — no cross-process
  # call on this per-owner 30s hot path.
  defp superseded? do
    case System.get_env("DEVIDE_HTTP_SOCKET") do
      our_socket when is_binary(our_socket) and our_socket != "" ->
        case File.read_link(current_socket_path()) do
          {:ok, ^our_socket} -> false
          {:ok, _other_socket} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  # Seam for tests: point the "which socket is live" symlink at a temp file the
  # test controls. Defaults to the real path.
  defp current_socket_path do
    Application.get_env(:dev_ide, :deployment_current_socket, @current_socket)
  end

  # Compare tmux's live window against `applied_size` and re-assert when an
  # external client (SSH attach, etc.) moved it. Cheap guard under manual mode.
  defp assert_tmux_window_size(
         %{workspace_key: key, info: %{sid: sid}, applied_size: size} = state
       )
       when is_binary(key) and is_binary(sid) and is_tuple(size) do
    if superseded?() do
      # A newer instance owns current.sock and these tmux sessions; re-asserting
      # here would drift-fight the live owner.
      state
    else
      case DevIDE.Deployment.Drain.guard_shared_write(fn -> :proceed end) do
        :noop ->
          # See start_tmux_resize/2: a draining instance's applied_size is stale by
          # definition — the replacement instance owns the shared size now.
          state

        _ ->
          do_assert_tmux_window_size(state, size)
      end
    end
  end

  defp assert_tmux_window_size(state), do: state

  # After this many consecutive drift re-asserts that never stick, escalate:
  # something else is writing the window size in a loop (a stale draining
  # instance, a duplicate owner on the same tmux session, an external
  # client). One warning per streak — the per-tick info lines continue.
  @drift_fight_threshold 4

  defp tmux_window_size_timeout_ms do
    Application.get_env(
      :dev_ide,
      :tmux_window_size_timeout_ms,
      @default_tmux_window_size_timeout_ms
    )
  end

  defp fetch_tmux_window_size(tmux, session) do
    timeout = tmux_window_size_timeout_ms()
    task = Task.async(fn -> tmux.window_size(session) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        Logger.warning(
          "tmux window_size timed out session=#{session} timeout_ms=#{timeout}",
          kind: :drift_guard
        )

        :error

      {:exit, reason} ->
        Logger.warning(
          "tmux window_size failed session=#{session} reason=#{inspect(reason)}",
          kind: :drift_guard
        )

        :error
    end
  end

  defp do_assert_tmux_window_size(%{workspace_key: key, info: %{sid: sid}} = state, size) do
    {cols, rows} = size
    session = Tmux.session_name(key, sid)
    tmux = DevIDE.Terminals.tmux_adapter()

    case fetch_tmux_window_size(tmux, session) do
      {:ok, {^cols, ^rows}} ->
        %{state | tmux_drift_streak: 0}

      {:ok, {actual_cols, actual_rows}} ->
        Logger.info(
          "tmux window drift #{actual_cols}x#{actual_rows} -> re-asserting #{cols}x#{rows}",
          kind: state.info.kind
        )

        streak = state.tmux_drift_streak + 1

        if streak == @drift_fight_threshold do
          Logger.warning(
            "tmux window size fight: #{streak} consecutive drift re-asserts " <>
              "(#{actual_cols}x#{actual_rows} keeps returning against applied " <>
              "#{cols}x#{rows}) — another writer is resizing this session " <>
              "(stale draining instance, duplicate owner, or external client); " <>
              "viewers=#{map_size(state.subscriber_sizes)}",
            kind: state.info.kind
          )

          :telemetry.execute(
            [:dev_ide, :terminals, :owner, :drift_fight],
            %{streak: streak},
            %{kind: state.info.kind, applied: size, actual: {actual_cols, actual_rows}}
          )

          emit_size_fight_alert(state, size, {actual_cols, actual_rows}, streak)
        end

        maybe_resize_tmux_window(%{state | tmux_drift_streak: streak}, cols, rows)

      :error ->
        state
    end
  end

  # Surface a sustained size fight in the notifications drawer, once per fight
  # episode (the caller gates on `streak == @drift_fight_threshold`, which is
  # crossed exactly once per streak). Routed through the audit spine so it
  # reaches both the in-app drawer and — where a device is registered — OS
  # push, via the `terminal.size_fight` alert definition. Fire-and-forget:
  # `Audit.emit!` swallows failures and no-ops without a workspace_id, so a
  # missing audit backend or an unscoped owner never disturbs the resize path.
  # Scratch is synthetic — skip audit rows for a non-existent workspace.
  defp emit_size_fight_alert(%{workspace_id: workspace_id} = state, {cols, rows}, actual, streak)
       when is_binary(workspace_id) do
    if DevIDE.Workspaces.Scratch.scratch?(workspace_id) do
      :ok
    else
      {actual_cols, actual_rows} = actual

      DevIDE.Audit.emit!(%{
        workspace_id: workspace_id,
        action: "terminal.size_fight",
        target_type: "terminal_session",
        target_ref: state.info.sid,
        reason:
          "another writer keeps resizing this terminal to #{actual_cols}x#{actual_rows} " <>
            "against the applied #{cols}x#{rows} (likely a stale instance from a recent deploy)",
        metadata: %{
          "kind" => to_string(state.info.kind),
          "applied" => "#{cols}x#{rows}",
          "observed" => "#{actual_cols}x#{actual_rows}",
          "streak" => streak,
          "session_id" => state.info.sid
        }
      })

      :ok
    end
  end

  defp emit_size_fight_alert(_state, _size, _actual, _streak), do: :ok

  defp schedule_tmux_drift_check(%{workspace_key: key, info: %{sid: sid}} = state)
       when is_binary(key) and is_binary(sid) do
    state = cancel_tmux_drift_timer(state)
    ref = Process.send_after(self(), :tmux_drift_check, @tmux_drift_check_interval_ms)
    %{state | tmux_drift_timer: ref}
  end

  defp schedule_tmux_drift_check(state), do: state

  defp cancel_tmux_drift_timer(%{tmux_drift_timer: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | tmux_drift_timer: nil}
  end

  defp cancel_tmux_drift_timer(state), do: state

  defp run_pending_tmux_resize(%{tmux_resize_pending: nil} = state), do: state

  defp run_pending_tmux_resize(%{tmux_resize_pending: {cols, rows}} = state) do
    maybe_resize_tmux_window(%{state | tmux_resize_pending: nil}, cols, rows)
  end

  # A fresh raw subscriber just received the replay snapshot: ask tmux to
  # repaint the full screen so live, authoritative content overwrites anything
  # the byte-tail replay could not reproduce exactly (it may span old grid
  # sizes). The redraw arrives as ordinary term_data after the replay —
  # ordering is naturally correct — and is idempotent for existing viewers.
  defp request_tmux_refresh(%{workspace_key: key, info: %{sid: sid}})
       when is_binary(key) and is_binary(sid) do
    _ =
      DevIDE.Deployment.Drain.guard_shared_write(fn ->
        session = Tmux.session_name(key, sid)
        tmux = DevIDE.Terminals.tmux_adapter()

        Task.Supervisor.start_child(DevIDE.TaskSupervisor, fn ->
          _ = tmux.refresh_client(session)
        end)
      end)

    :ok
  end

  defp request_tmux_refresh(_state), do: :ok

  defp send_input_to_attachment(%{attachment: attachment}, data)
       when not is_nil(attachment) and is_binary(data) do
    Attachment.send_input(attachment, data)
  end

  defp send_input_to_attachment(_state, _data), do: :ok

  # --- Single-responder query policy ------------------------------------------
  #
  # One SessionOwner multiplexes a single tmux client PTY to N viewer emulators.
  # When tmux emits a terminal query (DSR `\e[6n`, OSC 10/11/12 color query,
  # OSC 4 palette query, ...) the bytes fan out to every viewer, EVERY emulator
  # answers, and every PaneWorker forwards its answer here — N responses (with
  # per-viewer theme colors for OSC) into one PTY. Exactly one must win.
  defp handle_query_response(state, from, data) do
    class = classify_query_response(data)

    {forwarded?, state} =
      if from == current_responder(state) do
        maybe_forward_query_response(state, class, data)
      else
        {false, state}
      end

    :telemetry.execute(
      [:dev_ide, :terminals, :owner, :query_response],
      %{count: 1},
      %{forwarded: forwarded?, class: class}
    )

    state
  end

  defp maybe_forward_query_response(state, class, data) do
    if class == :theme_report and not tmux_reports_pane_theme?() do
      {false, state}
    else
      do_maybe_forward_query_response(state, class, data)
    end
  end

  defp do_maybe_forward_query_response(state, class, data) do
    now = System.monotonic_time(:millisecond)

    case state.last_response do
      # The responder can flip between two answers to the SAME query (e.g. a
      # focus change lands between the fan-out and the replies), so responder
      # gating alone still lets two answers through. A same-class answer this
      # close to the last forwarded one is that duplicate, not a new query.
      {^class, last_ms} when now - last_ms < @query_response_dedupe_ms ->
        {false, state}

      _ ->
        {theme, state} = owner_theme(state)

        data =
          data
          |> Theme.rewrite_pty_write(theme)
          |> maybe_rewrite_theme_reports(class, state.theme_scheme)

        send_input_to_attachment(state, data)
        {true, %{state | last_response: {class, now}}}
    end
  end

  defp maybe_rewrite_theme_reports(data, :theme_report, scheme),
    do: Theme.rewrite_theme_reports(data, scheme)

  defp maybe_rewrite_theme_reports(data, _class, _scheme), do: data

  defp classify_query_response(data) do
    cond do
      Regex.match?(@cpr_response, data) -> :cpr
      Regex.match?(@da_response, data) -> :device_attrs
      Regex.match?(@decrpm_response, data) -> :decrpm
      Regex.match?(@kitty_response, data) -> :kitty_keyboard
      Regex.match?(@osc_color_response, data) -> :osc_color
      Regex.match?(@osc_palette_response, data) -> :osc_palette
      Regex.match?(@xtversion_response, data) -> :xtversion
      Regex.match?(@theme_report_response, data) -> :theme_report
      true -> :other
    end
  end

  # The responder is DERIVED per message, never stored: a stored responder pid
  # would need explicit handoff on every detach/DOWN/focus flip and could go
  # stale between them. Deriving it from the same recency data the size policy
  # already maintains means prune/DOWN self-heal for free. Election order:
  # most-recently-active viewer (same recency rule as `active_sized_viewers/1`),
  # else a viewer whose reported size matches the applied PTY size (its grid is
  # authoritative), else the min pid — any deterministic pick beats N answers.
  defp current_responder(state) do
    actives =
      for {subscriber, {true, seq}} <- state.subscriber_active,
          Map.has_key?(state.subscribers, subscriber),
          do: {seq, subscriber}

    cond do
      actives != [] ->
        actives |> Enum.max_by(fn {seq, _subscriber} -> seq end) |> elem(1)

      subscriber = applied_size_subscriber(state) ->
        subscriber

      map_size(state.subscribers) > 0 ->
        state.subscribers |> Map.keys() |> Enum.min()

      true ->
        nil
    end
  end

  defp applied_size_subscriber(%{applied_size: nil}), do: nil

  defp applied_size_subscriber(state) do
    Enum.find_value(state.subscriber_sizes, fn {subscriber, size} ->
      if size == state.applied_size and Map.has_key?(state.subscribers, subscriber) do
        subscriber
      end
    end)
  end

  defp owner_theme(%{theme: %Theme{} = theme} = state), do: {theme, state}

  defp owner_theme(state) do
    theme =
      state.theme_preset
      |> Theme.load_bundle()
      |> Theme.active(state.theme_scheme)

    {theme, %{state | theme: theme}}
  end

  # tmux >= 3.5 queries the client for fg/bg at attach and accepts unsolicited
  # OSC 10/11 reports at any time (tty_keys_colours), then answers in-pane
  # `\e]11;?` queries itself. On <= 3.4 there is no such parser, so the same
  # bytes would surface as key input inside a pane — hard version-gated, and a
  # no-op until the host tmux cutover installs a >= 3.6 binary (pinned 3.7).
  defp tmux_tracks_client_colors? do
    case DevIDE.Terminals.tmux_version() do
      {_major, _minor} = version -> version >= {3, 5}
      _ -> false
    end
  end

  # tmux >= 3.6 parses explicit `?997;1n` / `?997;2n` client theme reports and
  # forwards them into panes that opted into DECSET 2031. On <= 3.5 those bytes
  # would surface as pane input — hard version-gated.
  defp tmux_reports_pane_theme? do
    case DevIDE.Terminals.tmux_version() do
      {_major, _minor} = version -> version >= {3, 6}
      _ -> false
    end
  end

  defp report_client_colors(state) do
    {theme, state} = owner_theme(state)

    payload =
      if tmux_reports_pane_theme?() do
        Theme.client_color_reports(theme) <> Theme.client_theme_report(state.theme_scheme)
      else
        Theme.client_color_reports(theme)
      end

    send_input_to_attachment(state, payload)
    state
  end

  # Agent sessions have no PTY backend yet (Attachment.open/2 returns
  # :agent_backend_unavailable). Register the subscriber without opening an
  # attachment so the session is viewable; input is a no-op until a backend
  # lands. This mirrors how attaching to an agent worked before raw-only.
  defp ensure_attachment(%{info: %Info{kind: :agent}} = state, _subscriber, :raw, _opts) do
    {
      :ok,
      state,
      %{
        mode: "raw",
        resumable: true,
        session_id: state.info.id
      }
    }
  end

  defp ensure_attachment(state, subscriber, :raw, opts) do
    state = replay_to_subscriber(state, subscriber)

    if state.attachment do
      {
        :ok,
        state,
        %{
          mode: "raw",
          cols: state.attachment.cols,
          rows: state.attachment.rows,
          resumable: true,
          session_id: state.info.id
        }
      }
    else
      with {:ok, attachment} <- open_attachment(state, opts) do
        Telemetry.owner_attachment_opened()

        s2 = %{state | attachment: attachment}

        s2 =
          if tmux_tracks_client_colors?() do
            report_client_colors(s2)
          else
            s2
          end

        {
          :ok,
          s2,
          %{
            mode: "raw",
            cols: attachment.cols,
            rows: attachment.rows,
            resumable: true,
            session_id: state.info.id
          }
        }
      end
    end
  end

  defp open_attachment(state, opts) do
    case state.info.kind do
      :shell ->
        workspace_key = state.workspace_key || Keyword.get(opts, :workspace_key)
        loc = state.loc || Keyword.get(opts, :loc)

        if is_binary(workspace_key) and is_tuple(loc) do
          Attachment.open(state.info,
            workspace_key: workspace_key,
            loc: loc,
            subscriber: self()
          )
        else
          {:error, :invalid_shell_attachment_opts}
        end

      _ ->
        Attachment.open(state.info, subscriber: self())
    end
  end

  defp broadcast_data(state, :shell, data, replay) do
    if map_size(state.raw_subscribers) == 0 do
      :ok
    else
      normalized = if is_binary(data), do: data, else: IO.iodata_to_binary(data)

      payload =
        build_data_payload(normalized, replay, if(replay, do: state.cursor, else: nil), state.gen)

      for pid <- state.raw_subscribers do
        send(pid, {:terminal_payload, :data, payload})
      end
    end
  end

  defp broadcast_data(state, _kind, data, replay) do
    if map_size(state.subscribers) == 0 do
      :ok
    else
      normalized = if is_binary(data), do: data, else: IO.iodata_to_binary(data)

      payload =
        build_data_payload(normalized, replay, if(replay, do: state.cursor, else: nil), state.gen)

      for {pid, _mode} <- state.subscribers do
        send(pid, {:terminal_payload, :data, payload})
      end
    end
  end

  defp broadcast_exit(subscribers, reason) do
    for {pid, _mode} <- subscribers do
      send(pid, {:terminal_payload, :exit, reason})
    end
  end

  defp prune_subscriber(state, subscriber) do
    case Map.get(state.subscribers, subscriber) do
      nil ->
        state

      _mode ->
        raw_state = maybe_remove_raw_subscriber(state, subscriber)

        ref = Map.get(state.subscriber_to_ref, subscriber)

        if ref do
          Process.demonitor(ref, [:flush])
        end

        raw_state
        |> Map.put(:subscribers, Map.delete(raw_state.subscribers, subscriber))
        |> Map.put(:subscriber_refs, Map.delete(raw_state.subscriber_refs, ref))
        |> Map.put(:subscriber_to_ref, Map.delete(raw_state.subscriber_to_ref, subscriber))
        |> forget_subscriber_view(subscriber)
    end
  end

  defp prune_subscriber_ref(state, ref) do
    case Map.get(state.subscriber_refs, ref) do
      nil ->
        state

      subscriber ->
        raw_state = maybe_remove_raw_subscriber(state, subscriber)

        %{
          raw_state
          | subscribers: Map.delete(raw_state.subscribers, subscriber),
            subscriber_refs: Map.delete(raw_state.subscriber_refs, ref),
            subscriber_to_ref: Map.delete(raw_state.subscriber_to_ref, subscriber)
        }
        |> forget_subscriber_view(subscriber)
    end
  end

  defp maybe_set_owner_subscriber_gauge(previous_state, next_state)
       when map_size(previous_state.subscribers) != map_size(next_state.subscribers) do
    Telemetry.set_owner_subscribers(self(), map_size(next_state.subscribers))
    next_state
  end

  defp maybe_set_owner_subscriber_gauge(_previous_state, next_state), do: next_state

  defp replay_to_subscriber(state, subscriber) do
    data = replay_data(state)

    if should_replay?(state) and byte_size(data) > 0 do
      payload = build_data_payload(data, true, state.cursor, state.gen)

      # Deliver the replay buffer synchronously from within the raw attach
      # handle_call (via ensure_attachment). GenServer serialization ensures
      # this send precedes the reply to the caller *and* any live term_data
      # handle_info that arrived concurrently (processed after this callback).
      # This eliminates replay/live interleaving for :raw attaches while
      # still supporting reconnect UX for raw channel attaches (shell/execution).
      # Payload metadata (`replay_frame`, `state_marker`) is forwarded to any
      # TerminalChannel client; the workspace UI uses Ghostty for raw PTY and
      # does not consume these markers today. The previous async drain queue
      # was the source of ordering races under concurrent PTY output.
      send(subscriber, {:terminal_payload, :data, payload})

      # Heal pass: the replay above is best-effort history; have tmux repaint
      # the authoritative screen on top of it (see request_tmux_refresh/1).
      request_tmux_refresh(state)

      state
    else
      state
    end
  end

  # The Session process's buffer is authoritative for shell attachments: it
  # captures output continuously, while this owner's replay_buffer only
  # accumulates while a raw subscriber is attached — an owner-buffer replay
  # misses everything produced between raw attaches. Streamer backends keep
  # using the owner buffer (they replay independently on attach and expose
  # no snapshot). Terminal handshakes AND OSC color queries are stripped at
  # read so stale startup probes/queries never reach a fresh subscriber or
  # trigger client replies (a replayed OSC 11 query would make every fresh
  # viewer re-answer it into the shared PTY). Replay-only: on the live path
  # queries must pass through so the elected responder can answer them.
  defp replay_data(%__MODULE__{attachment: %Attachment{} = attachment} = state) do
    case Attachment.snapshot(attachment) do
      {:ok, snapshot} ->
        {clean, _cursor} = TerminalCtl.Escape.strip_handshakes(snapshot)
        TerminalCtl.Escape.strip_color_queries(clean)

      :unavailable ->
        TerminalCtl.Escape.strip_color_queries(state.replay_buffer)
    end
  end

  defp replay_data(state), do: TerminalCtl.Escape.strip_color_queries(state.replay_buffer)

  defp should_replay?(%__MODULE__{info: %Info{kind: :shell}}), do: true

  defp should_replay?(_state), do: false

  # Enriched replay payload with state marker for raw channel reconnect UX.
  # `replay_frame: true` + `state_marker` let TerminalChannel clients
  # distinguish buffered scrollback from live PTY output. Cursor metadata is
  # opportunistic: if a backend emits a cursor report, it is captured and
  # stripped before broadcast/buffering; otherwise clients get the pending
  # placeholder.
  defp build_data_payload(data, true, cursor, gen) when is_binary(data) do
    %{
      data: data,
      gen: gen,
      replay: true,
      replay_frame: true,
      state_marker: %{
        kind: "replay",
        cursor: cursor || %{row: nil, col: nil, pending: true},
        ts: System.system_time(:millisecond)
      }
    }
  end

  defp build_data_payload(data, _replay, _cursor, gen) when is_binary(data),
    do: %{data: data, gen: gen}

  # --- backpressure / burst protection + cursor capture helpers (item 4/5) ---

  defp check_backpressure(state) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, len} when len > 500 ->
        subs = map_size(state.subscribers || %{})

        kind = state.info.kind

        Logger.warning(
          "terminal owner high mailbox (backpressure); fast PTY + viewers may cause growth",
          queue_len: len,
          subscribers: subs,
          kind: kind
        )

        :telemetry.execute(
          [:dev_ide, :terminals, :owner, :backpressure],
          %{queue_len: len},
          %{kind: kind, subscriber_count: subs}
        )

      _ ->
        :ok
    end
  end

  defp update_raw_subscriber_last_seen(state) do
    raw_subs = state.raw_subscribers

    if MapSet.size(raw_subs) == 0 do
      state
    else
      now = System.monotonic_time()
      seen0 = state.raw_subscriber_last_seen || %{}

      new_seen =
        Enum.reduce(MapSet.to_list(raw_subs), seen0, fn pid, acc ->
          case Process.info(pid, :message_queue_len) do
            {:message_queue_len, ql} ->
              if ql > 50 do
                Logger.warning(
                  "slow_raw_viewer (subscriber mbox high; viewer struggling to keep up)",
                  subscriber: inspect(pid),
                  subscriber_mbox: ql,
                  kind: state.info.kind
                )

                :telemetry.execute(
                  [:dev_ide, :terminals, :owner, :slow_raw_viewer],
                  %{subscriber_mbox: ql},
                  %{kind: (state.info && state.info.kind) || nil}
                )
              end

              Map.put(acc, pid, now)

            _ ->
              Map.delete(acc, pid)
          end
        end)

      %{state | raw_subscriber_last_seen: new_seen}
    end
  end

  # Common path for all term_data: backpressure check, last_data stamp,
  # cursor capture+strip, conditional append (preserves maybe logic),
  # broadcast of *clean* data, last_seen update for slow heuristic.
  defp handle_term_data(state, data, replay) when is_binary(data) do
    check_backpressure(state)
    capture_replay? = should_capture_replay?(state)

    {clean, maybe_cursor} =
      if capture_replay? do
        TerminalCtl.Escape.strip_handshakes(data)
      else
        {data, nil}
      end

    clean = if is_binary(clean), do: clean, else: IO.iodata_to_binary(clean)

    state =
      if maybe_cursor do
        %{state | cursor: maybe_cursor}
      else
        state
      end

    next_state =
      if capture_replay? do
        append_output_buffer(state, clean)
      else
        state
      end

    # Bump before command tracking and broadcast so the stamped gen covers this chunk.
    next_state =
      if replay do
        next_state
      else
        next_state
        |> bump_content_gen()
        |> track_commands(clean)
      end

    broadcast_data(next_state, state.info.kind, clean, replay)
    # Only run slow-viewer qlen inspection for live (non-replay) deliveries;
    # replay frames are internal reconnect UX and do not represent sustained
    # live data pressure on raw subscribers.
    if replay do
      next_state
    else
      update_raw_subscriber_last_seen(next_state)
    end
  end

  # Replay is re-delivery of retained bytes for reconnect UX, not new
  # content, so callers skip this for replay chunks and the generation never
  # moves without live output.
  defp bump_content_gen(state) do
    state = %{state | gen: state.gen + 1}

    if state.event_emit_scheduled? do
      state
    else
      Process.send_after(self(), :emit_session_event, @event_emit_interval_ms)
      %{state | event_emit_scheduled?: true}
    end
  end

  defp track_commands(%{command_tracker: nil} = state, _data), do: state

  defp track_commands(state, data) when is_binary(data) do
    %{state | command_tracker: CommandTracker.ingest(state.command_tracker, data, state.gen)}
  end

  defp append_output_buffer(state, data) when is_binary(data) do
    replay_buffer =
      TerminalCtl.Replay.append(state.replay_buffer, data, state.replay_buffer_limit)

    %{state | replay_buffer: replay_buffer}
  end

  # (maybe_append removed; logic inlined in handle_term_data to support
  # cursor stripping + backpressure for all term_data while preserving
  # "only append when raw subs present" behavior.)

  defp has_raw_subscriber?(%__MODULE__{raw_subscribers: raw_subscribers}) do
    MapSet.size(raw_subscribers) > 0
  end

  defp should_capture_replay?(state) do
    should_replay?(state) and has_raw_subscriber?(state)
  end

  defp adjust_raw_subscribers(state, subscriber, nil, :raw),
    do: %{state | raw_subscribers: MapSet.put(state.raw_subscribers, subscriber)}

  defp adjust_raw_subscribers(state, _subscriber, nil, _mode), do: state

  defp adjust_raw_subscribers(state, _subscriber, :raw, :raw), do: state

  defp adjust_raw_subscribers(state, subscriber, :raw, _mode),
    do: %{state | raw_subscribers: MapSet.delete(state.raw_subscribers, subscriber)}

  defp adjust_raw_subscribers(state, subscriber, _prev, :raw),
    do: %{state | raw_subscribers: MapSet.put(state.raw_subscribers, subscriber)}

  defp adjust_raw_subscribers(state, _subscriber, _prev, _mode), do: state

  defp maybe_remove_raw_subscriber(state, subscriber) do
    %{
      state
      | raw_subscribers: MapSet.delete(state.raw_subscribers, subscriber),
        raw_subscriber_last_seen: Map.delete(state.raw_subscriber_last_seen, subscriber)
    }
  end

  # Determines whether this owner process should terminate after a detach.
  # :shell owners are intentionally immortal (tied to tmux session lifetime via
  # `tmux new-session -A` and reused across clients). :agent owners are
  # ephemeral and stop once their last subscriber detaches.
  # (Private helper; see also the public attach/detach docs in this module and
  # in DevIDE.Terminals for the immortality contract.)
  defp should_stop?(state) do
    case state.info.kind do
      :agent -> map_size(state.subscribers) == 0
      _ -> false
    end
  end

  defp tmux_session_name_for(key, sid)
       when is_binary(key) and is_binary(sid) and sid != "",
       do: Tmux.session_name(key, sid)

  defp tmux_session_name_for(_key, _sid), do: nil
end
