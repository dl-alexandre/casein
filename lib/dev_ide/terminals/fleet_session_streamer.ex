defmodule DevIDE.Terminals.FleetSessionStreamer do
  @moduledoc """
  Streamer for attaching to existing fleet tmux sessions (local or remote).

  Phase 3 direction:
  - Will support remote backends by delegating to runner adapters instead of direct TmuxAdapter.
  - The `loc` or `runner_id` on the session will determine the backend.
  """

  use GenServer
  require Logger

  alias DevIDE.Terminals.TmuxAdapter

  @poll_interval 250

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :tmux_session)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # Client API

  def subscribe(pid, subscriber) do
    GenServer.cast(pid, {:subscribe, subscriber})
  end

  def send_input(pid, data) do
    GenServer.cast(pid, {:send_input, data})
  end

  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  # Server

  @impl true
  def init(opts) do
    tmux_session = Keyword.fetch!(opts, :tmux_session)
    subscriber = Keyword.get(opts, :subscriber)

    if TmuxAdapter.session_alive?(tmux_session) do
      state = %{
        tmux_session: tmux_session,
        subscribers: if(subscriber, do: [subscriber], else: []),
        last_capture_bytes: 0
      }

      if subscriber, do: subscribe(self(), subscriber)
      send(self(), :poll)
      {:ok, state}
    else
      {:stop, {:tmux_session_not_found, tmux_session}}
    end
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | subscribers: [pid | state.subscribers] |> Enum.uniq()}}
  end

  @impl true
  def handle_cast({:send_input, data}, state) do
    TmuxAdapter.send_keys(state.tmux_session, data)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case TmuxAdapter.capture(state.tmux_session) do
      {:ok, output} ->
        {diff, captured_bytes} = capture_diff(output, state.last_capture_bytes)

        if diff != "" do
          Enum.each(state.subscribers, fn pid ->
            send(pid, {:term_data, diff})
          end)
        end

        schedule_poll()
        {:noreply, %{state | last_capture_bytes: captured_bytes}}

      _ ->
        schedule_poll()
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subscribers = Enum.reject(state.subscribers, &(&1 == pid))
    {:noreply, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.debug("FleetSessionStreamer stopped for #{state.tmux_session}")
    :ok
  end

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

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end
end
