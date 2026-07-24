defmodule TmuxCtl.Events.ControlListener do
  @moduledoc """
  Read-only tmux control-mode listener for host-server topology notifications.

  Opens `tmux -L <label> -C attach-session -t <anchor>` (default anchor
  `__devide_keepalive`) and broadcasts pure notification events on
  `"tmux_events:<label>"`. Never writes shared tmux state — the only bytes sent
  on the control channel are the client-local `refresh-client -f no-output`.

  Connect failures use internal backoff (never crash-loop the supervisor).
  Attach-only: cannot spawn a missing server (probe-verified).
  """

  use GenServer

  require Logger

  alias TmuxCtl.Events.Parser

  @default_anchor "__devide_keepalive"
  @default_backoff_ms [1_000, 2_000, 4_000, 8_000, 16_000, 30_000]
  # A connection must stay up this long before disconnect resets backoff to
  # the floor (prevents fast connect/die flaps from retrying at 1s forever).
  @sustained_connection_ms 60_000
  # Sliding window used by `:status` `reconnects_in_window` (Slice 3 observability).
  @reconnect_window_ms 300_000
  @topic_prefix "tmux_events:"

  @type state_name :: :connecting | :connected | :backoff

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Return listener status:
  `%{state, label, connected_since, reconnects, reconnects_in_window}`.

  `reconnects` is lifetime; `reconnects_in_window` counts downs in the last
  5 minutes (for flap / soak dashboards).
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @impl true
  def init(opts) do
    label = Keyword.fetch!(opts, :label)
    pubsub = Keyword.fetch!(opts, :pubsub)

    state = %{
      label: label,
      pubsub: pubsub,
      tmux_bin: Keyword.get_lazy(opts, :tmux_bin, fn -> System.find_executable("tmux") end),
      anchor_session:
        Keyword.get(opts, :anchor_session) ||
          Application.get_env(:casein, :tmux_events_anchor_session, @default_anchor),
      backoff_ms: Keyword.get(opts, :backoff_ms, @default_backoff_ms),
      backoff_index: 0,
      state: :connecting,
      port: nil,
      in_block?: false,
      connected_since: nil,
      reconnects: 0,
      # Monotonic ms of each successful-connection disconnect (for window count).
      reconnect_times: [],
      connect_timer: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, do_connect(state)}

  @impl true
  def handle_call(:status, _from, state) do
    now = System.monotonic_time(:millisecond)

    reply = %{
      state: state.state,
      label: state.label,
      connected_since: state.connected_since,
      reconnects: state.reconnects,
      reconnects_in_window: reconnects_in_window(state.reconnect_times, now)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:connect, state), do: {:noreply, do_connect(state)}

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) when is_port(port) do
    {:noreply, handle_line(state, line)}
  end

  def handle_info({port, {:data, {:noeol, _chunk}}}, %{port: port} = state) when is_port(port) do
    # Oversized line fragment — drop and keep listening.
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) when is_port(port) do
    {:noreply, handle_disconnect(state, :exit_status)}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) when is_port(port) do
    {:noreply, handle_disconnect(state, :port_exit)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state)
    :ok
  end

  # -- connect / disconnect -------------------------------------------------

  defp do_connect(%{state: :connected} = state), do: state

  defp do_connect(state) do
    state = cancel_connect_timer(state)

    case open_port(state) do
      {:ok, port} ->
        emit_telemetry(:reconnect_attempt, state)

        %{
          state
          | port: port,
            state: :connecting,
            in_block?: false,
            connected_since: nil
        }

      {:error, reason} ->
        Logger.debug("tmux control listener connect failed (#{state.label}): #{inspect(reason)}")
        emit_telemetry(:reconnect_attempt, state)
        enter_backoff(state)
    end
  end

  defp open_port(%{tmux_bin: nil}), do: {:error, :tmux_not_found}

  defp open_port(%{tmux_bin: tmux_bin, label: label, anchor_session: anchor}) do
    port =
      Port.open(
        {:spawn_executable, tmux_bin},
        [
          :binary,
          {:line, 16_384},
          :exit_status,
          :stderr_to_stdout,
          args: ["-L", label, "-C", "attach-session", "-t", anchor]
        ]
      )

    {:ok, port}
  rescue
    e -> {:error, e}
  end

  defp handle_disconnect(state, reason) do
    was_connected? = state.state == :connected
    now = System.monotonic_time(:millisecond)
    state = close_port(state)

    state =
      if was_connected? do
        reconnects = state.reconnects + 1
        reconnect_times = prune_reconnect_times([now | state.reconnect_times], now)

        state = %{
          state
          | reconnects: reconnects,
            reconnect_times: reconnect_times
        }

        broadcast_lifecycle(state, :listener_down)
        emit_telemetry(:down, state)
        state
      else
        state
      end

    Logger.debug(
      "tmux control listener disconnected (#{state.label}): #{inspect(reason)}; backing off"
    )

    # Only a sustained connection earns a reset to the backoff floor; short
    # lived connections keep climbing so a connect/die flap can't spin at 1s.
    sustained? =
      is_integer(state.connected_since) and
        now - state.connected_since >= @sustained_connection_ms

    state = if sustained?, do: %{state | backoff_index: 0}, else: state

    enter_backoff(%{state | state: :backoff, connected_since: nil, in_block?: false})
  end

  defp enter_backoff(state) do
    delay = backoff_delay(state)
    timer = Process.send_after(self(), :connect, delay)

    %{
      state
      | state: :backoff,
        port: nil,
        connect_timer: timer,
        backoff_index: min(state.backoff_index + 1, length(state.backoff_ms) - 1)
    }
  end

  defp backoff_delay(state) do
    Enum.at(state.backoff_ms, state.backoff_index) || List.last(state.backoff_ms) || 30_000
  end

  # -- line handling --------------------------------------------------------

  defp handle_line(state, line) do
    # Attach failure text (no server / no session) arrives as plain stderr lines
    # rather than %-notifications; treat as disconnect into backoff.
    if state.state == :connecting and attach_error_line?(line) do
      handle_disconnect(state, {:attach_error, line})
    else
      parse_and_dispatch(state, line)
    end
  end

  defp parse_and_dispatch(%{in_block?: true} = state, line) do
    case Parser.parse_line(line) do
      :end_block ->
        mark_connected_if_needed(%{state | in_block?: false})

      :begin ->
        state

      _ ->
        state
    end
  end

  defp parse_and_dispatch(state, line) do
    case Parser.parse_line(line) do
      :begin ->
        mark_connected_if_needed(%{state | in_block?: true})

      :end_block ->
        mark_connected_if_needed(%{state | in_block?: false})

      :ignore ->
        # A bare non-notification while connecting is not progress.
        state

      {:event, %{type: :exit} = event} ->
        state
        |> mark_connected_if_needed()
        |> broadcast_event(event)
        |> handle_disconnect(:exit_notification)

      {:event, event} ->
        state
        |> mark_connected_if_needed()
        |> broadcast_event(event)
    end
  end

  defp mark_connected_if_needed(%{state: :connected} = state), do: state

  defp mark_connected_if_needed(state) do
    now = System.monotonic_time(:millisecond)

    # First successful signal on this port: silence output and announce up.
    if state.port do
      _ = Port.command(state.port, "refresh-client -f no-output\n")
    end

    state = %{
      state
      | state: :connected,
        connected_since: now
        # backoff_index deliberately NOT reset here: a connection must stay up
        # for @sustained_connection_ms before the disconnect path resets to the
        # floor, otherwise a fast connect/die flap retries at 1s forever.
    }

    broadcast_lifecycle(state, :listener_up)
    emit_telemetry(:up, state)
    state
  end

  defp attach_error_line?(line) when is_binary(line) do
    String.contains?(line, "no server running") or
      String.contains?(line, "error connecting") or
      String.contains?(line, "can't find session") or
      String.contains?(line, "no current session") or
      String.contains?(line, "failed to connect")
  end

  # -- broadcast / telemetry ------------------------------------------------

  defp broadcast_event(state, event) do
    event = Map.put(event, :server, state.label)

    Phoenix.PubSub.broadcast(
      state.pubsub,
      topic(state.label),
      {TmuxCtl.Events, {:tmux_event, event}}
    )

    state
  end

  defp broadcast_lifecycle(state, kind) when kind in [:listener_up, :listener_down] do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      topic(state.label),
      {TmuxCtl.Events, {kind, state.label}}
    )

    state
  end

  defp topic(label), do: @topic_prefix <> label

  defp emit_telemetry(event, state) when event in [:up, :down, :reconnect_attempt] do
    now = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:tmux_ctl, :events, :listener],
      %{
        count: 1,
        reconnects: state.reconnects,
        reconnects_in_window: reconnects_in_window(state.reconnect_times, now)
      },
      %{event: event, label: state.label, reconnects: state.reconnects}
    )
  end

  defp reconnects_in_window(times, now) when is_list(times) do
    times
    |> prune_reconnect_times(now)
    |> length()
  end

  defp prune_reconnect_times(times, now) do
    cutoff = now - @reconnect_window_ms
    Enum.filter(times, &(&1 > cutoff))
  end

  # -- port helpers ---------------------------------------------------------

  defp close_port(%{port: nil} = state), do: state

  defp close_port(%{port: port} = state) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    %{state | port: nil}
  end

  defp cancel_connect_timer(%{connect_timer: nil} = state), do: state

  defp cancel_connect_timer(%{connect_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | connect_timer: nil}
  end
end
