defmodule DevIDE.Terminals.SessionOwner do
  @moduledoc """
  Per-session terminal owner process.

  Owns one logical session (shell/execution/agent placeholder) and multiplexes
  backend output to all attached channel callers for that logical session.
  """

  use GenServer
  require Logger

  alias DevIDE.BoundedBuffer
  alias DevIDE.Terminals.{Attachment, Boundary, Session.Info}
  alias DevIDE.Terminals.Telemetry

  # Default replay buffer; overridable via Application env for the knob.
  # See `replay_buffer_limit/0`.
  @default_replay_buffer_bytes 32 * 1024

  # Replay chunking constants (client-side effect only). These are extracted
  # so the 96-byte / 5 ms values are clearly linked to the server-side
  # reconnect/replay UX. Matches the implementation and comments in
  # assets/js/terminal_hook.js (_renderReplayFrame and surrounding).
  @replay_chunk_size 96
  @replay_chunk_delay_ms 5
  # Silenced here (immediately after definition) solely to suppress "unused module
  # attribute" warnings while exposing the values for JS cross-reference in
  # assets/js/terminal_hook.js (_renderReplayFrame). These are documentation
  # constants only; see replay_buffer_limit/0 and the JS comment for values.
  _ = [@replay_chunk_size, @replay_chunk_delay_ms]

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
    raw_subscribers: MapSet.new(),
    subscribers: %{},
    subscriber_refs: %{},
    subscriber_to_ref: %{},
    raw_subscriber_last_seen: %{},
    cursor: nil
  ]

  def owner_key(%Info{kind: :execution} = info),
    do: {:terminal_owner, :execution, to_string(info.execution_id)}

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

  def resize(owner_pid, cols, rows)
      when is_pid(owner_pid) and is_integer(cols) and is_integer(rows) do
    GenServer.cast(owner_pid, {:resize, cols, rows})
    :ok
  end

  @doc """
  Cheap subscriber count for a live owner pid. Returns map_size(subscribers).
  Intended for LiveView/channel presence badges ("N viewers on this shell")
  and dashboard UX. Does not distinguish raw vs governed.
  """
  def subscriber_count(owner_pid) when is_pid(owner_pid) do
    GenServer.call(owner_pid, :subscriber_count)
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
      |> Map.put(:workspace_key, Keyword.get(opts, :workspace_key))
      |> Map.put(:loc, Keyword.get(opts, :loc))
      |> Map.put(:host_id, Keyword.get(opts, :host_id))

    case ensure_attachment(state, subscriber, mode, opts) do
      {:ok, next_state, payload} ->
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
  # Intentionally does not distinguish raw vs. governed subscribers (returns
  # map_size of the combined subscribers map). This matches the documented
  # "cheap" public contract of subscriber_count/1 and the
  # Terminals.owner_subscriber_count/1 delegate (used by presence/UX/telemetry).
  def handle_call(:subscriber_count, _from, state) do
    {:reply, map_size(state.subscribers), state}
  end

  def handle_call({:resize, cols, rows}, _from, state)
      when is_integer(cols) and is_integer(rows) do
    {:reply, :ok, resize_attachment(state, cols, rows)}
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

  @impl true
  def handle_cast({:resize, cols, rows}, state) do
    {:noreply, resize_attachment(state, cols, rows)}
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
    broadcast_exit(state.subscribers, reason)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:term_exit, _ref, reason}, state) do
    broadcast_exit(state.subscribers, reason)
    {:stop, :normal, state}
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

  @impl true
  def handle_info(_, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Telemetry.owner_stopped(self())

    if state.attachment != nil do
      Telemetry.owner_attachment_closed()
    end

    if state.attachment do
      Attachment.close(state.attachment)
    end

    :ok
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
    case GenServer.call(pid, {:attach, subscriber, mode, opts}) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resize_attachment(state, cols, rows) do
    if state.attachment do
      Attachment.resize(state.attachment, cols, rows)
    end

    state
  end

  defp send_input_to_attachment(%{attachment: attachment}, data)
       when not is_nil(attachment) and is_binary(data) do
    Attachment.send_input(attachment, data)
  end

  defp send_input_to_attachment(_state, _data), do: :ok

  defp ensure_attachment(state, _subscriber, :governed, opts) do
    raw_available? = Keyword.get(opts, :raw_available?, false)
    commands = Boundary.command_examples(raw_available?: raw_available?)

    case state.info.kind do
      :execution when state.attachment == nil ->
        with {:ok, attachment} <- open_attachment(state) do
          Telemetry.owner_attachment_opened()

          {
            :ok,
            %{state | attachment: attachment},
            %{
              mode: "governed",
              commands: commands,
              raw_available: raw_available?,
              resumable: true,
              session_id: state.info.id
            }
          }
        end

      _ ->
        {
          :ok,
          state,
          %{
            mode: "governed",
            commands: commands,
            raw_available: raw_available?,
            resumable: state.info.kind != :shell,
            session_id: state.info.id
          }
        }
    end
  end

  defp ensure_attachment(state, subscriber, :raw, opts) do
    state = replay_to_subscriber(state, subscriber)

    if state.attachment do
      state = request_cursor_position(state)

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
        s2 = request_cursor_position(s2)

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

  defp open_attachment(state, opts \\ []) do
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
      payload = build_data_payload(normalized, replay, if(replay, do: state.cursor, else: nil))

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
      payload = build_data_payload(normalized, replay, if(replay, do: state.cursor, else: nil))

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
    end
  end

  defp maybe_set_owner_subscriber_gauge(previous_state, next_state)
       when map_size(previous_state.subscribers) != map_size(next_state.subscribers) do
    Telemetry.set_owner_subscribers(self(), map_size(next_state.subscribers))
    next_state
  end

  defp maybe_set_owner_subscriber_gauge(_previous_state, next_state), do: next_state

  defp replay_to_subscriber(state, subscriber) do
    if should_replay?(state) and byte_size(state.replay_buffer) > 0 do
      payload = build_data_payload(state.replay_buffer, true, state.cursor)

      # Deliver the replay buffer synchronously from within the raw attach
      # handle_call (via ensure_attachment). GenServer serialization ensures
      # this send precedes the reply to the caller *and* any live term_data
      # handle_info that arrived concurrently (processed after this callback).
      # This eliminates replay/live interleaving for :raw attaches while
      # still supporting reconnect UX (the JS hook renders replay_frame payloads
      # with badge + muted styling). The previous async drain queue was the
      # source of ordering races under concurrent PTY output.
      send(subscriber, {:terminal_payload, :data, payload})

      state
    else
      state
    end
  end

  defp should_replay?(%__MODULE__{info: %Info{kind: kind}})
       when kind in [:shell, :execution] do
    true
  end

  defp should_replay?(_state), do: false

  # Enriched replay payload with state marker for reconnect UX.
  # `replay_frame: true` + `state_marker` let clients (e.g. terminal_hook.js)
  # render replay appends distinctly (muted style, delayed chunks, badge).
  # For channel-raw attaches (owner-controlled), `cursor` is populated with
  # real %{row, col, pending: false} by driving a DSR query ("\e[?6n") via
  # Attachment/PTY on raw attach and capturing the CPR response in term_data
  # (stripped before broadcast or buffer to avoid leaking control bytes).
  # Ghostty LV path untouched. Falls back to %{row: nil, col: nil, pending: true}
  # placeholder when no CPR response has arrived yet.
  defp build_data_payload(data, true, cursor) when is_binary(data) do
    %{
      data: data,
      replay: true,
      replay_frame: true,
      state_marker: %{
        kind: "replay",
        cursor: cursor || %{row: nil, col: nil, pending: true},
        ts: System.system_time(:millisecond)
      }
    }
  end

  defp build_data_payload(data, _replay, _cursor) when is_binary(data), do: %{data: data}

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

  # Strip DSR/CPR cursor reports from incoming PTY data (for channel-raw path)
  # and return last seen cursor. Reports are removed so they never enter the
  # replay buffer or get sent to any subscribers (prevents control bytes from
  # appearing in xterm or history). Uses cheap early-out for hot path.
  # The \e[ guard is sufficient; any data with unrelated ESC seqs (\e], \e(, OSC)
  # still pays Regex cost, but CPR is exercised only on raw-attach queries (rare
  # vs. live PTY volume) so the accepted cost is negligible.
  defp strip_and_capture_cursor_reports(data) when is_binary(data) do
    if :binary.match(data, "\e[") == :nomatch do
      {data, nil}
    else
      # Support both DSR responses with/without ? ( \e[12;34R or \e[?12;34R )
      case Regex.scan(~r/\e\[\??(\d+);(\d+)R/, data, capture: :all_but_first) do
        [] ->
          {data, nil}

        caps ->
          case List.last(caps) do
            [row_s, col_s] ->
              row = String.to_integer(row_s)
              col = String.to_integer(col_s)
              clean = Regex.replace(~r/\e\[\??\d+;\d+R/, data, "")
              {clean, %{row: row, col: col, pending: false}}

            _ ->
              {data, nil}
          end
      end
    end
  end

  # Fire a non-blocking cursor position query through the PTY for the
  # channel-raw path only. Response arrives async via term_data, is captured
  # (and stripped) by the handler above, and made available for subsequent
  # raw attaches' state_markers. Uses existing send_input/Attachment path.
  defp request_cursor_position(state) do
    if state.attachment do
      Attachment.send_input(state.attachment, "\e[?6n")
    end

    state
  end

  # Common path for all term_data: backpressure check, last_data stamp,
  # cursor capture+strip, conditional append (preserves maybe logic),
  # broadcast of *clean* data, last_seen update for slow heuristic.
  defp handle_term_data(state, data, replay) when is_binary(data) do
    check_backpressure(state)
    capture_replay? = should_capture_replay?(state)

    {clean, maybe_cursor} =
      if capture_replay? do
        strip_and_capture_cursor_reports(data)
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

  defp append_output_buffer(state, data) when is_binary(data) do
    replay_buffer = BoundedBuffer.append(state.replay_buffer, data, state.replay_buffer_limit)
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
  # `tmux new-session -A` and reused across clients). Only :execution and :agent
  # owners are ephemeral and stop once their last subscriber detaches.
  # (Private helper; see also the public attach/detach docs in this module and
  # in DevIDE.Terminals for the immortality contract.)
  defp should_stop?(state) do
    case state.info.kind do
      kind when kind in [:execution, :agent] -> map_size(state.subscribers) == 0
      _ -> false
    end
  end
end
