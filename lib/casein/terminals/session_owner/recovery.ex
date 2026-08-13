defmodule Casein.Terminals.SessionOwner.Recovery do
  @moduledoc false

  # #934 constraint: this module holds SessionOwner recover/term_exit callback
  # bodies only. It is not a process. SessionOwner remains the one GenServer
  # per tmux session — do not add start_link/init here or change when a shell
  # recovers vs when an agent owner stops. Historic constants below must stay
  # byte-identical to the pre-split SessionOwner attributes.

  require Logger

  alias Casein.Terminals.{Attachment, Backend, ScrollbackArchive, Session.Info, SessionRecovery}
  alias Casein.Terminals.SessionOwner
  alias Casein.Terminals.Telemetry

  @backend_recover_max 5
  @backend_recover_backoff_ms 400

  @doc false
  def backend_recover_max, do: @backend_recover_max

  @doc false
  def backend_recover_backoff_ms, do: @backend_recover_backoff_ms

  @doc false
  def handle_backend_recover(state) do
    state = %{state | backend_recover_timer: nil}

    # A concurrent raw attach may have already reopened the attachment while
    # this timer was pending. Opening again would leak the first handle and
    # double-count Telemetry.open_attachments.
    if state.attachment do
      {:noreply, %{state | backend_recover_attempts: 0}}
    else
      case attempt_backend_recover(state) do
        {:stop, reason, next} -> {:stop, reason, next}
        next -> {:noreply, next}
      end
    end
  end

  @doc false
  def handle_session_exists_reply(state, probe, result) do
    Process.demonitor(probe.ref, [:flush])
    _ = SessionOwner.cancel_timer_ref(probe.timer)
    state = %{state | tmux_session_exists_probe: nil}
    exists? = result == true
    apply_session_exists_result(state, probe.session, probe.purpose, exists?)
  end

  @doc false
  def handle_session_exists_down(state, probe) do
    _ = SessionOwner.cancel_timer_ref(probe.timer)
    state = %{state | tmux_session_exists_probe: nil}
    # Treat crash as "exists" for drift (avoid thrashing recover); recover path
    # still proceeds with missing?=false so open_attachment can decide.
    apply_session_exists_result(state, probe.session, probe.purpose, true)
  end

  @doc false
  def handle_session_exists_timeout(state, probe) do
    Process.demonitor(probe.ref, [:flush])
    Process.exit(probe.pid, :kill)

    Logger.warning(
      "tmux session_exists? timed out session=#{probe.session} timeout_ms=#{SessionOwner.tmux_window_size_timeout_ms()}",
      kind: :drift_guard
    )

    state = %{state | tmux_session_exists_probe: nil}
    # Timeout → assume still present so we don't spuriously recover.
    apply_session_exists_result(state, probe.session, probe.purpose, true)
  end

  # Shell owners with live viewers re-open the Session attachment instead of
  # dying — tmux -A recreates an empty session if the server wiped, and
  # ScrollbackArchive reseeds history when available. Agent placeholders and
  # owners with no subscribers keep the legacy broadcast+stop path.
  @doc false
  def handle_term_exit(%{info: %Info{kind: :shell}} = state, reason) do
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

  def handle_term_exit(state, reason) do
    broadcast_exit(state.subscribers, reason)
    {:stop, :normal, state}
  end

  @doc false
  def clear_dead_attachment(%{attachment: nil} = state), do: state

  def clear_dead_attachment(state) do
    Telemetry.owner_attachment_closed()
    # Session is already dead; close is best-effort.
    try do
      Attachment.close(state.attachment)
    catch
      :exit, _ -> :ok
    end

    %{state | attachment: nil}
  end

  @doc false
  def schedule_backend_recover(state) do
    state = cancel_backend_recover_timer(state)
    ref = Process.send_after(self(), :backend_recover, @backend_recover_backoff_ms)
    %{state | backend_recover_timer: ref}
  end

  @doc false
  def cancel_backend_recover_timer(%{backend_recover_timer: ref} = state)
      when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | backend_recover_timer: nil}
  end

  def cancel_backend_recover_timer(state), do: state

  defp attempt_backend_recover(state) do
    attempts = state.backend_recover_attempts + 1

    if attempts > @backend_recover_max do
      Logger.error(
        "terminal owner backend recover exhausted attempts=#{attempts}; stopping owner"
      )

      broadcast_exit(state.subscribers, :backend_recover_failed)
      {:stop, :normal, %{state | backend_recover_attempts: attempts}}
    else
      state = %{state | backend_recover_attempts: attempts}
      session = tmux_session_for(state)

      if is_binary(session) do
        # session_exists? shells out with no timeout on the adapter — probe
        # off-process, then continue recover when the result arrives.
        start_session_exists_probe(state, session, {:continue_recover, attempts})
      else
        continue_backend_recover(state, attempts, _missing? = false)
      end
    end
  end

  defp continue_backend_recover(state, attempts, missing?) do
    # Race: ensure_attachment/4 may have reopened between schedule and fire.
    if state.attachment do
      %{state | backend_recover_attempts: 0}
    else
      do_continue_backend_recover(state, attempts, missing?)
    end
  end

  defp do_continue_backend_recover(state, attempts, missing?) do
    session = tmux_session_for(state)
    history_restored? = is_binary(session) and ScrollbackArchive.present?(session)

    case SessionOwner.open_attachment(state, []) do
      {:ok, attachment} ->
        Logger.info(
          "terminal owner backend recovered attempt=#{attempts} session=#{session} missing=#{missing?}"
        )

        Telemetry.owner_attachment_opened()

        :telemetry.execute(
          [:casein, :terminals, :owner, :backend_recovered],
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
          if SessionOwner.tmux_tracks_client_colors?() do
            SessionOwner.report_client_colors(s2)
          else
            s2
          end

        # Replay retained Session buffer, then re-assert the last known
        # viewer size so a fresh new-session is not left at bootstrap geometry.
        s2
        |> SessionOwner.replay_all_raw_subscribers()
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

  defp reassert_size_after_recover(%{applied_size: {cols, rows}} = state)
       when is_integer(cols) and is_integer(rows) do
    state
    |> SessionOwner.maybe_resize_tmux_window(cols, rows)
    |> then(fn s ->
      if s.attachment do
        _ = Attachment.resize(s.attachment, cols, rows)
      end

      s
    end)
    |> SessionOwner.assert_tmux_window_size()
  end

  defp reassert_size_after_recover(state), do: SessionOwner.assert_tmux_window_size(state)

  defp tmux_session_for(%{workspace_key: key, info: %{sid: sid}})
       when is_binary(key) and is_binary(sid),
       do: Backend.module().session_name(key, sid)

  defp tmux_session_for(_), do: nil

  # Drift tick: if the tmux session vanished under us (server wipe) while the
  # PTY client is still somehow attached, force a backend recover.
  # session_exists? shells out with no timeout — probe off-process.
  @doc false
  def maybe_recover_missing_tmux_session(
        %{workspace_key: key, info: %{kind: :shell, sid: sid}, attachment: att} = state
      )
      when is_binary(key) and is_binary(sid) and not is_nil(att) do
    session = Backend.module().session_name(key, sid)
    start_session_exists_probe(state, session, :recover_if_missing)
  end

  def maybe_recover_missing_tmux_session(state), do: state

  # Single-flight async session_exists? — mirrors window_size probe. `purpose`
  # decides what to do when the result arrives (see apply_session_exists_result/4).
  # Drift probes coalesce (skip if in flight); recover always restarts so a
  # term_exit recover is never dropped behind a slow drift probe.
  defp start_session_exists_probe(state, session, :recover_if_missing)
       when is_binary(session) do
    case state.tmux_session_exists_probe do
      nil -> do_start_session_exists_probe(state, session, :recover_if_missing)
      _in_flight -> state
    end
  end

  defp start_session_exists_probe(state, session, {:continue_recover, _} = purpose)
       when is_binary(session) do
    state
    |> cancel_session_exists_probe()
    |> do_start_session_exists_probe(session, purpose)
  end

  defp do_start_session_exists_probe(state, session, purpose) do
    backend = Backend.module()

    task =
      Task.Supervisor.async_nolink(Casein.TaskSupervisor, fn ->
        session_exists?(backend, session, state.loc)
      end)

    timer =
      Process.send_after(
        self(),
        {:tmux_session_exists_timeout, task.ref},
        SessionOwner.tmux_window_size_timeout_ms()
      )

    %{
      state
      | tmux_session_exists_probe: %{
          ref: task.ref,
          pid: task.pid,
          session: session,
          timer: timer,
          purpose: purpose
        }
    }
  end

  defp session_exists?(backend, session, {:local, cwd})
       when is_binary(cwd) and cwd != "" do
    if function_exported?(backend, :session_exists?, 2) do
      backend.session_exists?(session, cwd: cwd)
    else
      backend.session_exists?(session)
    end
  end

  defp session_exists?(backend, session, _loc), do: backend.session_exists?(session)

  defp cancel_session_exists_probe(
         %{tmux_session_exists_probe: %{ref: ref, pid: pid, timer: timer}} = state
       ) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    _ = SessionOwner.cancel_timer_ref(timer)
    %{state | tmux_session_exists_probe: nil}
  end

  defp cancel_session_exists_probe(state), do: state

  defp apply_session_exists_result(state, _session, :recover_if_missing, true), do: state

  defp apply_session_exists_result(state, session, :recover_if_missing, false) do
    Logger.warning("tmux session missing under live owner; recovering session=#{session}")

    # Notify is deferred until successful recover (UUID + history flags
    # accurate). Dedupe covers any race with term_exit recover.
    state
    |> clear_dead_attachment()
    |> schedule_backend_recover()
  end

  defp apply_session_exists_result(state, _session, {:continue_recover, attempts}, exists?) do
    continue_backend_recover(state, attempts, not exists?)
  end

  defp broadcast_exit(subscribers, reason) do
    for {pid, _mode} <- subscribers do
      send(pid, {:terminal_payload, :exit, reason})
    end
  end
end
