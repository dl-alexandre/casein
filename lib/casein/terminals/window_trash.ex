defmodule Casein.Terminals.WindowTrash do
  @moduledoc """
  Deferred, undoable window close.

  Closing a tmux window is destructive and irreversible — it takes every
  process running in it. This module makes the *viewer* treat a close as
  immediate while leaving tmux untouched for a grace period, so the close can
  still be taken back.

  Trashing a window records `{session, window_id}` here and arms a timer.
  Until that timer fires nothing has happened to tmux: the window, its panes,
  and everything running in them are still alive and still attached. What
  changed is only what viewers are shown — `TerminalState.assign_tmux_topology/3`
  filters trashed ids out of the window list, so the window disappears from
  every tab strip, picker, and sidebar in the session. Restoring cancels the
  timer and the window reappears intact. When the timer does fire we run the
  real `kill-window`.

  ## Why this is session-wide and not per-viewer

  The pending set lives here, in one process, rather than in a LiveView assign,
  because a tmux window is shared state:

    * LiveView sockets die and remount constantly (reconnect, navigation). A
      socket-local "hidden" flag would resurrect the window mid-countdown and
      then kill it anyway a few seconds later.
    * A second viewer with no knowledge of the pending close would keep working
      in a window that vanishes under them when the timer fires.

  So every viewer on the session hides the window together, and any of them can
  take the close back.

  ## Failure direction

  Every failure mode here resolves toward *not* killing the window. If this
  process crashes, the ETS table it owns dies with it, the pending set is empty
  on restart, and the trashed windows simply reappear — an undo timer lost to a
  crash or a deploy costs a close, never a window. That is deliberate: the
  reverse (a window dying because state was lost) is the outcome the grace
  period exists to prevent.
  """

  use GenServer

  require Logger

  alias Casein.Terminals

  @table __MODULE__.Pending
  @default_grace_ms 30_000

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  How long a trashed window stays recoverable, in milliseconds.
  """
  @spec grace_ms() :: pos_integer()
  def grace_ms do
    case Application.get_env(:casein, :window_trash_grace_ms, @default_grace_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_grace_ms
    end
  end

  @doc """
  Hides `window_id` from every viewer on `session` and schedules the real kill.

  `name` is kept only so the undo affordance can name the window it is offering
  to bring back. Returns the grace period so the caller can render a countdown.
  """
  @spec trash(String.t(), String.t(), String.t() | nil) ::
          {:ok, pos_integer()} | {:error, term()}
  def trash(session, window_id, name \\ nil)
      when is_binary(session) and is_binary(window_id) do
    GenServer.call(__MODULE__, {:trash, session, window_id, name})
  end

  @doc """
  Takes back a pending close: cancels the kill and unhides the window.
  """
  @spec restore(String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, :not_pending}
  def restore(session, window_id) when is_binary(session) and is_binary(window_id) do
    GenServer.call(__MODULE__, {:restore, session, window_id})
  end

  @doc """
  Restores the most recently trashed window on `session`.

  Backs the `C-b r` binding, which carries no window id — the useful reading of
  "undo" from a keystroke is always the last thing you did.
  """
  @spec restore_latest(String.t()) ::
          {:ok, String.t(), String.t() | nil} | {:error, :nothing_pending}
  def restore_latest(session) when is_binary(session) do
    GenServer.call(__MODULE__, {:restore_latest, session})
  end

  @doc """
  Ids currently hidden on `session`.

  Read straight from ETS: this runs on every topology assign, which is a hot
  path (activity polls re-assign topology on every viewer), so it must not
  serialize through the GenServer.
  """
  @spec pending_ids(String.t()) :: MapSet.t(String.t())
  def pending_ids(session) when is_binary(session) do
    @table
    |> :ets.match({{session, :"$1"}, :_, :_})
    |> Enum.map(fn [window_id] -> window_id end)
    |> MapSet.new()
  rescue
    ArgumentError -> MapSet.new()
  end

  @doc """
  Drops trashed windows from a topology window list.
  """
  @spec reject_pending(String.t() | nil, [map()]) :: [map()]
  def reject_pending(session, windows) when is_binary(session) and is_list(windows) do
    pending = pending_ids(session)

    if MapSet.size(pending) == 0 do
      windows
    else
      Enum.reject(windows, &MapSet.member?(pending, Map.get(&1, :id)))
    end
  end

  def reject_pending(_session, windows), do: windows

  @doc """
  True when `window_id` is hidden pending a deferred kill.
  """
  @spec pending?(String.t(), String.t()) :: boolean()
  def pending?(session, window_id) when is_binary(session) and is_binary(window_id) do
    MapSet.member?(pending_ids(session), window_id)
  end

  @doc """
  PubSub topic carrying `{:window_trash_changed, session}` on every trash,
  restore, and expiry.
  """
  @spec topic(String.t()) :: String.t()
  def topic(session), do: "tmux_window_trash:#{session}"

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(session) when is_binary(session) do
    Phoenix.PubSub.subscribe(Casein.PubSub, topic(session))
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session) when is_binary(session) do
    Phoenix.PubSub.unsubscribe(Casein.PubSub, topic(session))
  end

  @doc false
  # Test helper — drops all pending state without killing anything.
  def __reset__, do: GenServer.call(__MODULE__, :__reset__)

  ## Server callbacks

  @impl true
  def init(_opts) do
    # Owned by this process on purpose: a crash must take the pending set with
    # it so trashed windows reappear instead of being stranded hidden with no
    # timer left to either kill or restore them.
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{timers: %{}}}
  end

  @impl true
  def handle_call({:trash, session, window_id, name}, _from, state) do
    key = {session, window_id}

    if Map.has_key?(state.timers, key) do
      # Already counting down — don't restart the clock out from under the
      # undo affordance that is already on screen.
      {:reply, {:ok, grace_ms()}, state}
    else
      grace = grace_ms()
      timer = Process.send_after(self(), {:expire, session, window_id}, grace)
      :ets.insert(@table, {key, name, System.monotonic_time(:millisecond)})
      broadcast(session)

      {:reply, {:ok, grace}, put_in(state.timers[key], timer)}
    end
  end

  def handle_call({:restore, session, window_id}, _from, state) do
    case pop_pending(state, session, window_id) do
      {nil, state} ->
        {:reply, {:error, :not_pending}, state}

      {name, state} ->
        broadcast(session)
        {:reply, {:ok, name}, state}
    end
  end

  def handle_call({:restore_latest, session}, _from, state) do
    case latest_pending(session) do
      nil ->
        {:reply, {:error, :nothing_pending}, state}

      window_id ->
        {name, state} = pop_pending(state, session, window_id)
        broadcast(session)
        {:reply, {:ok, window_id, name}, state}
    end
  end

  def handle_call(:__reset__, _from, state) do
    Enum.each(state.timers, fn {_key, timer} -> Process.cancel_timer(timer) end)
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | timers: %{}}}
  end

  @impl true
  def handle_info({:expire, session, window_id}, state) do
    {_name, state} = pop_pending(state, session, window_id)

    # The window may already be gone — it can exit on its own during the grace
    # period, in which case tmux errors here and the topology watcher has long
    # since dropped it. Nothing to do either way but stop tracking it.
    case Terminals.tmux_adapter().kill_window(session, window_id) do
      :ok ->
        Logger.info("WindowTrash: closed #{session}:#{window_id} after grace period")

      {:error, reason} ->
        Logger.info(
          "WindowTrash: deferred close of #{session}:#{window_id} " <>
            "did not apply (#{inspect(reason)})"
        )
    end

    broadcast(session)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  defp pop_pending(state, session, window_id) do
    key = {session, window_id}

    case :ets.lookup(@table, key) do
      [{^key, name, _trashed_at}] ->
        :ets.delete(@table, key)
        {timer, timers} = Map.pop(state.timers, key)
        if timer, do: Process.cancel_timer(timer)
        {name || "", %{state | timers: timers}}

      [] ->
        {nil, state}
    end
  end

  defp latest_pending(session) do
    @table
    |> :ets.match({{session, :"$1"}, :_, :"$2"})
    |> case do
      [] -> nil
      rows -> rows |> Enum.max_by(fn [_id, at] -> at end) |> hd()
    end
  end

  defp broadcast(session) do
    Phoenix.PubSub.broadcast(
      Casein.PubSub,
      topic(session),
      {:window_trash_changed, session}
    )
  end
end
