defmodule DevIDE.Terminals.RemoteOutputStreamer do
  @moduledoc """
  Streamer for fleet executions whose tmux session lives on a remote runner.

  Unlike `FleetSessionStreamer`, this never touches local tmux. It subscribes
  to the execution's PubSub topic (`fleet:executions:<id>`) emitted by
  `Fleet.LocalRunnerAdapter` when it ingests OutputChunk protocol messages.
  Cached history is replayed once via `DevIDE.Fleet.execution_output_tail/2` so
  the operator doesn't see a blank pane on attach.

  Remote executions are **read-only**: there's no protocol path from the
  cockpit to the remote tmux pty, so `send_input/2` is a no-op.

  Lifecycle: stops when its single subscriber goes away, or when the execution
  reaches a terminal state (broadcast via the same topic).
  """

  use GenServer
  require Logger

  alias DevIDE.Fleet
  alias DevIDE.Fleet.Notification

  @pubsub DevIde.PubSub
  @replay_tail 200

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :execution_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def subscribe(pid, subscriber), do: GenServer.cast(pid, {:subscribe, subscriber})
  def send_input(_pid, _data), do: :ok
  def stop(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(opts) do
    execution_id = Keyword.fetch!(opts, :execution_id)
    subscriber = Keyword.get(opts, :subscriber)

    :ok = Phoenix.PubSub.subscribe(@pubsub, "fleet:executions:#{execution_id}")

    # Lease lifecycle events (`:lease_expired`, etc.) are broadcast by
    # `Fleet.Registry` on the *assignment* topic — they don't carry an
    # execution_id and so never reach the execution topic. Look up the
    # assignment_id once at init and subscribe to that topic as well.
    assignment_id =
      case Fleet.get_execution_projection(execution_id) do
        {:ok, %{assignment_id: aid}} when is_binary(aid) ->
          :ok = Phoenix.PubSub.subscribe(@pubsub, "fleet:assignments:#{aid}")
          aid

        _ ->
          nil
      end

    state = %{
      execution_id: execution_id,
      assignment_id: assignment_id,
      subscribers: if(subscriber, do: [subscriber], else: []),
      subscriber_mons: monitor_pids(if(subscriber, do: [subscriber], else: [])),
      # Per-stream last seq, since stdout and stderr have independent counters
      # on the producer. A single counter would treat a stderr=1 arriving after
      # stdout=5 as a regression and silently drop it.
      last_seq: %{}
    }

    if subscriber, do: send(self(), {:replay, subscriber})
    {:ok, state}
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    if pid in state.subscribers do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      send(self(), {:replay, pid})

      {:noreply,
       %{
         state
         | subscribers: [pid | state.subscribers],
           subscriber_mons: Map.put(state.subscriber_mons, ref, pid)
       }}
    end
  end

  @impl true
  def handle_info({:replay, pid}, state) do
    chunks = Fleet.execution_output_tail(state.execution_id, @replay_tail)

    Enum.each(chunks, fn %{chunk: chunk} ->
      if Process.alive?(pid), do: send(pid, {:term_data, chunk})
    end)

    # Seed per-stream last_seq from the replayed chunks so the first live chunk
    # after attach isn't treated as a gap. Only update tracking — chunks have
    # already been fanned out above.
    new_last_seq =
      Enum.reduce(chunks, state.last_seq, fn entry, acc ->
        case {entry[:stream] || entry["stream"], entry[:seq] || entry["seq"]} do
          {stream, seq} when is_binary(stream) and is_integer(seq) ->
            Map.update(acc, stream, seq, &max(&1, seq))

          _ ->
            acc
        end
      end)

    {:noreply, %{state | last_seq: new_last_seq}}
  end

  # OutputChunk broadcast from LocalRunnerAdapter (Track B — remote resilience).
  # Per-stream seq tracking detects gaps (runner→controller chunk loss) without
  # treating stdout and stderr as a single ordered sequence.
  def handle_info(
        {DevIDE.Fleet.LocalRunnerAdapter, %Notification{kind: :output_chunk, payload: payload}},
        state
      ) do
    chunk = payload[:chunk] || payload["chunk"]
    stream = payload[:stream] || payload["stream"] || "stdout"
    this_seq = payload[:seq] || payload["seq"]
    last_seq = Map.get(state.last_seq, stream)

    cond do
      is_nil(chunk) ->
        # Defensive: malformed payload, ignore.
        {:noreply, state}

      not is_integer(this_seq) ->
        # Legacy producer without seq — pass through, don't update tracking.
        fan_out(state, chunk)
        {:noreply, state}

      is_integer(last_seq) and this_seq <= last_seq ->
        # Duplicate or out-of-order. PubSub + TCP should give in-order delivery,
        # so this is rare enough to drop rather than try to reorder.
        {:noreply, state}

      is_integer(last_seq) and this_seq > last_seq + 1 ->
        # Gap. Surface it as a one-line marker so operators can see data was
        # lost rather than wonder why output looks discontinuous.
        missing = this_seq - last_seq - 1

        gap_msg =
          "\r\n[output gap on #{stream}: #{missing} chunk(s) lost between seq #{last_seq + 1} and #{this_seq - 1}]\r\n"

        fan_out(state, gap_msg)
        fan_out(state, chunk)
        {:noreply, put_in(state.last_seq[stream], this_seq)}

      true ->
        fan_out(state, chunk)
        {:noreply, put_in(state.last_seq[stream], this_seq)}
    end
  end

  # Track B — unified handling for terminal states and runner unreachable
  def handle_info(
        {DevIDE.Fleet.LocalRunnerAdapter, %Notification{kind: kind, execution_id: id}},
        %{execution_id: id} = state
      ) do
    cond do
      execution_terminal?(kind) ->
        Enum.each(state.subscribers, &send(&1, {:term_exit, :execution_finished}))
        {:stop, :normal, state}

      kind in [:execution_abandoned, :lease_expired] ->
        Enum.each(state.subscribers, &send(&1, {:term_exit, :runner_unreachable}))
        {:stop, :normal, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({DevIDE.Fleet.LocalRunnerAdapter, _other}, state), do: {:noreply, state}

  # Lease lifecycle events from Fleet.Registry on the assignment topic. The
  # registry broadcasts with itself as the tag, not LocalRunnerAdapter, so a
  # separate clause is required. Lease expiry on an in-flight execution means
  # the runner missed its renewal window — for our purposes, unreachable.
  def handle_info(
        {DevIDE.Fleet.Registry, %Notification{kind: :lease_expired, assignment_id: aid}},
        %{assignment_id: aid} = state
      )
      when is_binary(aid) do
    Enum.each(state.subscribers, &send(&1, {:term_exit, :runner_unreachable}))
    {:stop, :normal, state}
  end

  def handle_info({DevIDE.Fleet.Registry, _other}, state), do: {:noreply, state}

  # Direct signal (e.g. from runner registry or transport layer)
  def handle_info({:runner_unreachable, execution_id}, %{execution_id: execution_id} = state) do
    Enum.each(state.subscribers, &send(&1, {:term_exit, :runner_unreachable}))
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    mons = Map.delete(state.subscriber_mons, ref)
    subs = Enum.reject(state.subscribers, &(&1 == pid))

    if subs == [] do
      {:stop, :normal, %{state | subscribers: [], subscriber_mons: mons}}
    else
      {:noreply, %{state | subscribers: subs, subscriber_mons: mons}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Logger.debug("RemoteOutputStreamer stopped for execution=#{state.execution_id}")
    :ok
  end

  defp fan_out(state, chunk) do
    Enum.each(state.subscribers, fn pid ->
      if Process.alive?(pid), do: send(pid, {:term_data, chunk})
    end)
  end

  defp monitor_pids(pids) do
    pids
    |> Enum.map(fn pid -> {Process.monitor(pid), pid} end)
    |> Map.new()
  end

  # Notification kinds emitted on completion / abandon / failure / expiry.
  # Conservative: any non-output_chunk notification whose payload looks terminal.
  defp execution_terminal?(:execution_completed), do: true
  defp execution_terminal?(:execution_failed), do: true
  defp execution_terminal?(:execution_abandoned), do: true
  defp execution_terminal?(:execution_expired), do: true
  defp execution_terminal?(_), do: false
end
