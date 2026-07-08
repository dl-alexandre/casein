defmodule DevIDE.Terminals.TmuxJanitor do
  @moduledoc """
  Idle GC for `devide_*` tmux sessions backing the Ghostty raw shell.

  Each LiveView that opens raw mode calls `subscribe/1` with its tmux
  session name; the janitor monitors the calling pid. When the last
  subscriber for a session leaves (explicit `unsubscribe/1` or `:DOWN`
  from the monitored pid), the janitor schedules `tmux kill-session` after
  `:tmux_idle_seconds`. A new subscriber arriving before the timer fires
  cancels the pending kill.

  Safety: only sessions whose name starts with `devide_` are killed.

  Configuration: `:tmux_idle_seconds` — integer seconds, or `nil` to
  disable (no kill ever scheduled). Default `nil`.
  """
  use GenServer

  require Logger

  alias DevIDE.Terminals.{SessionOwner, Tmux}

  @prefix "devide_"

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register the calling pid as a subscriber to `session`. Monitors the
  caller; on `:DOWN` it is treated as `unsubscribe/1`. Sessions whose name
  does not start with `devide_` are silently ignored — the janitor only
  manages tmux sessions it owns.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(session) when is_binary(session) do
    if String.starts_with?(session, @prefix) do
      GenServer.cast(__MODULE__, {:subscribe, session, self()})
    else
      :ok
    end
  end

  @doc """
  Deregister the calling pid from `session`. If no subscribers remain and
  idle GC is configured, schedule a kill.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session) when is_binary(session) do
    if String.starts_with?(session, @prefix) do
      GenServer.cast(__MODULE__, {:unsubscribe, session, self()})
    else
      :ok
    end
  end

  @doc false
  # Test helper — synchronous snapshot of internal state.
  def __state__, do: GenServer.call(__MODULE__, :__state__)

  ## Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}, monitors: %{}}}
  end

  @impl true
  def handle_cast({:subscribe, session, pid}, state) do
    ref = Process.monitor(pid)

    entry =
      Map.get(state.sessions, session, %{subscribers: MapSet.new(), kill_timer: nil})

    if entry.kill_timer, do: Process.cancel_timer(entry.kill_timer)

    entry = %{
      subscribers: MapSet.put(entry.subscribers, pid),
      kill_timer: nil
    }

    state =
      state
      |> put_in([:sessions, session], entry)
      |> put_in([:monitors, ref], {pid, session})

    {:noreply, state}
  end

  def handle_cast({:unsubscribe, session, pid}, state) do
    {:noreply, drop_subscriber(state, session, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{^pid, session}, monitors} ->
        {:noreply, drop_subscriber(%{state | monitors: monitors}, session, pid)}
    end
  end

  def handle_info({:kill_idle, session}, state) do
    case Map.get(state.sessions, session) do
      %{subscribers: subs} = entry ->
        cond do
          MapSet.size(subs) > 0 ->
            # Subscribers re-appeared; clear stale kill_timer ref defensively.
            {:noreply, put_in(state.sessions[session], %{entry | kill_timer: nil})}

          String.starts_with?(session, @prefix) ->
            if SessionOwner.durable_shell_session?(session) do
              Logger.info("TmuxJanitor: skipping idle kill for durable shell #{session}")
              {:noreply, %{state | sessions: Map.delete(state.sessions, session)}}
            else
              Logger.info("TmuxJanitor: killing idle session #{session}")
              _ = Tmux.kill(session)
              {:noreply, %{state | sessions: Map.delete(state.sessions, session)}}
            end

          true ->
            # Defensive: refuse to kill anything outside our namespace.
            # Drop the bookkeeping so we don't keep firing on it.
            {:noreply, %{state | sessions: Map.delete(state.sessions, session)}}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:__state__, _from, state), do: {:reply, state, state}

  ## Internals

  defp drop_subscriber(state, session, pid) do
    case Map.get(state.sessions, session) do
      nil ->
        state

      entry ->
        subs = MapSet.delete(entry.subscribers, pid)

        cond do
          MapSet.size(subs) > 0 ->
            put_in(state.sessions[session], %{entry | subscribers: subs})

          idle_ms() == nil ->
            # GC disabled — drop the bookkeeping but never kill.
            %{state | sessions: Map.delete(state.sessions, session)}

          true ->
            timer = Process.send_after(self(), {:kill_idle, session}, idle_ms())
            put_in(state.sessions[session], %{subscribers: subs, kill_timer: timer})
        end
    end
  end

  defp idle_ms do
    case Application.get_env(:dev_ide, :tmux_idle_seconds) do
      n when is_integer(n) and n > 0 -> n * 1000
      _ -> nil
    end
  end
end
