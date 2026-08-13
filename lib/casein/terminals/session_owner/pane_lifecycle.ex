defmodule Casein.Terminals.SessionOwner.PaneLifecycle do
  @moduledoc false

  # #934 constraint: this module holds SessionOwner attach/detach/DOWN callback
  # bodies only. It is not a process. SessionOwner remains the one GenServer
  # per tmux session — do not add start_link/init here. Shell owners stay
  # immortal after the last detach; agent owners stop. Do not flip that policy
  # in a decomposition change.

  require Logger

  alias Casein.Terminals.Session.Info
  alias Casein.Terminals.SessionOwner
  alias Casein.Terminals.SessionOwner.Recovery
  alias Casein.Terminals.Telemetry

  @doc false
  def handle_attach(state, subscriber, mode, opts) do
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

        :telemetry.execute([:casein, :terminals, :owner, :attach], %{count: 1}, %{
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

        :telemetry.execute([:casein, :terminals, :owner, :attach], %{count: 1}, %{
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
          |> SessionOwner.assert_tmux_window_size()
          |> SessionOwner.schedule_tmux_drift_check()

        if next_state.applied_size do
          {cols, rows} = next_state.applied_size
          SessionOwner.broadcast_owner_size(next_state.subscribers, cols, rows)
        end

        maybe_set_owner_subscriber_gauge(previous_state, next_state)
        {:reply, {:ok, payload}, next_state}

      {:error, reason} ->
        Logger.warning("terminal owner attach error", reason: inspect(reason), mode: mode)

        :telemetry.execute([:casein, :terminals, :owner, :attach_error], %{count: 1}, %{
          reason: inspect(reason),
          mode: mode
        })

        reply_state = if fresh?, do: prune_subscriber(state, subscriber), else: state
        maybe_set_owner_subscriber_gauge(previous_state, reply_state)
        {:reply, {:error, reason}, reply_state}
    end
  end

  @doc false
  def handle_detach(state, subscriber) do
    Logger.debug("terminal owner detach", subscriber: subscriber, kind: state.info.kind)

    :telemetry.execute([:casein, :terminals, :owner, :detach], %{count: 1}, %{
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

  @doc false
  def handle_subscriber_down(state, ref) do
    next_state = prune_subscriber_ref(state, ref)
    maybe_set_owner_subscriber_gauge(state, next_state)

    if should_stop?(next_state) do
      {:stop, :normal, next_state}
    else
      {:noreply, next_state}
    end
  end

  # Attachment context binds once per owner. A later attach without these opts
  # (e.g. a re-join that omits :loc) or with a conflicting value must not
  # clobber the context the live attachment was opened with.
  @doc false
  def bind_attachment_context(state, _key, nil), do: state

  def bind_attachment_context(state, key, value) do
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
          [:casein, :terminals, :owner, :binding_conflict],
          %{count: 1},
          %{key: key, kind: state.info.kind}
        )

        state
    end
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
    state = SessionOwner.replay_to_subscriber(state, subscriber)

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
      with {:ok, attachment} <- SessionOwner.open_attachment(state, opts) do
        Telemetry.owner_attachment_opened()

        # Cancel any pending term_exit recover so it cannot open a second
        # attachment and leak the handle / Telemetry.open_attachments count.
        s2 =
          %{state | attachment: attachment, backend_recover_attempts: 0}
          |> Recovery.cancel_backend_recover_timer()
          |> maybe_seed_client_colors()

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
        |> SessionOwner.forget_subscriber_view(subscriber)
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
        |> SessionOwner.forget_subscriber_view(subscriber)
    end
  end

  defp maybe_set_owner_subscriber_gauge(previous_state, next_state)
       when map_size(previous_state.subscribers) != map_size(next_state.subscribers) do
    Telemetry.set_owner_subscribers(self(), map_size(next_state.subscribers))
    next_state
  end

  defp maybe_set_owner_subscriber_gauge(_previous_state, next_state), do: next_state

  defp adjust_raw_subscribers(state, subscriber, nil, :raw),
    do: %{state | raw_subscribers: MapSet.put(state.raw_subscribers, subscriber)}

  defp adjust_raw_subscribers(state, _subscriber, nil, _mode), do: state

  defp adjust_raw_subscribers(state, _subscriber, :raw, :raw), do: state

  defp adjust_raw_subscribers(state, subscriber, :raw, _mode),
    do: %{state | raw_subscribers: MapSet.delete(state.raw_subscribers, subscriber)}

  defp adjust_raw_subscribers(state, subscriber, _prev, :raw),
    do: %{state | raw_subscribers: MapSet.put(state.raw_subscribers, subscriber)}

  defp adjust_raw_subscribers(state, _subscriber, _prev, _mode), do: state

  defp maybe_seed_client_colors(state) do
    if SessionOwner.tmux_tracks_client_colors?() do
      SessionOwner.report_client_colors(state)
    else
      state
    end
  end

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
  # (Private helper; see also the public attach/detach docs in SessionOwner and
  # in Casein.Terminals for the immortality contract.)
  @doc false
  def should_stop?(state) do
    case state.info.kind do
      :agent -> map_size(state.subscribers) == 0
      _ -> false
    end
  end
end
