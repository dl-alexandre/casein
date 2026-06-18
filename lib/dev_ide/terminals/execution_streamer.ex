defmodule DevIDE.Terminals.ExecutionStreamer do
  @moduledoc """
  Read-only output streamer for `:execution` terminal sessions.

  Execution sessions have no interactive PTY path from the cockpit, so this
  backend is read-only: `send_input/2` is a no-op. It fans cached/streamed
  output to subscribers and stops when its last subscriber goes away.

  When the session is backed by a live local tmux session, output is polled
  and diffed; otherwise it simply manages the subscriber lifecycle (the
  delegated-execution streamers that produced remote output were removed, so
  there is no live remote source to ingest).
  """

  use GenServer

  alias DevIDE.Terminals.TmuxAdapter

  @poll_interval 250
  @max_consecutive_failures 8

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :tmux_session) || Keyword.get(opts, :execution_id)},
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
    tmux_session = Keyword.get(opts, :tmux_session)
    subscriber = Keyword.get(opts, :subscriber)
    poll? = is_binary(tmux_session) and adapter().session_alive?(tmux_session)

    state = %{
      tmux_session: tmux_session,
      poll?: poll?,
      subscribers: if(subscriber, do: [subscriber], else: []),
      last_capture_bytes: 0,
      consecutive_failures: 0
    }

    if subscriber, do: Process.monitor(subscriber)
    if poll?, do: send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    if pid in state.subscribers do
      {:noreply, state}
    else
      Process.monitor(pid)
      {:noreply, %{state | subscribers: [pid | state.subscribers]}}
    end
  end

  @impl true
  def handle_info(:poll, %{poll?: true} = state) do
    case adapter().capture(state.tmux_session) do
      {:ok, output} ->
        {diff, captured_bytes} = capture_diff(output, state.last_capture_bytes)
        if diff != "", do: broadcast(state.subscribers, {:term_data, diff})
        schedule_poll()
        {:noreply, %{state | last_capture_bytes: captured_bytes, consecutive_failures: 0}}

      _ ->
        handle_capture_failure(state)
    end
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.reject(state.subscribers, &(&1 == pid)) do
      [] -> {:stop, :normal, %{state | subscribers: []}}
      remaining -> {:noreply, %{state | subscribers: remaining}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp handle_capture_failure(state) do
    failures = state.consecutive_failures + 1

    cond do
      not adapter().session_alive?(state.tmux_session) ->
        broadcast(state.subscribers, {:term_exit, :tmux_session_ended})
        {:stop, :normal, state}

      failures >= @max_consecutive_failures ->
        broadcast(state.subscribers, {:term_exit, :capture_failed})
        {:stop, :normal, state}

      true ->
        schedule_poll()
        {:noreply, %{state | consecutive_failures: failures}}
    end
  end

  defp broadcast(subscribers, message) do
    Enum.each(subscribers, fn pid ->
      if Process.alive?(pid), do: send(pid, message)
    end)
  end

  defp adapter, do: Application.get_env(:dev_ide, :execution_tmux_adapter, TmuxAdapter)

  defp capture_diff(output, previous_bytes) do
    captured_bytes = byte_size(output)

    diff =
      cond do
        captured_bytes > previous_bytes ->
          binary_part(output, previous_bytes, captured_bytes - previous_bytes)

        captured_bytes < previous_bytes ->
          output

        true ->
          ""
      end

    {diff, captured_bytes}
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval)
end
