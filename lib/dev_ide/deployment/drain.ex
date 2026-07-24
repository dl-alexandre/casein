defmodule Casein.Deployment.Drain do
  @moduledoc """
  Counts active LiveView connections and coordinates graceful shutdown
  when a deploy drain is initiated.

  On drain start, broadcasts an update-available notice over PubSub and
  waits for connections to drop to zero before stopping the VM. A hard
  timeout ensures the node eventually exits even if connections never
  fully close.

  Because "New version available" is now a passive bell signal (clients no
  longer auto-reload on it), connections rarely reach zero on their own. After
  `@auto_reconnect_ms` still draining with clients attached, we broadcast
  `{:deploy_reconnect}` so those clients do a background LiveSocket reconnect
  onto the live instance — draining this node in ~seconds instead of lingering
  until the hard timeout.
  """

  use GenServer

  @grace_ms 5_000
  @hard_ms 1_800_000
  @auto_reconnect_ms 90_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec track(pid()) :: :ok
  def track(pid) do
    GenServer.cast(__MODULE__, {:track, pid})
  end

  @spec start_drain(non_neg_integer()) :: :ok | {:error, :already_draining}
  def start_drain(commits_behind \\ 0) do
    GenServer.call(__MODULE__, {:start_drain, commits_behind})
  end

  @spec draining?() :: boolean()
  def draining? do
    GenServer.call(__MODULE__, :draining?)
  end

  @doc """
  Runs `fun` when this node is not draining a deploy; returns `:noop` otherwise.

  Shared tmux-server and box-global writers must use this so a draining canary
  does not stomp state the replacement instance owns. Degrades to running `fun`
  when the Drain server is unavailable (slim test trees).
  """
  @spec guard_shared_write((-> term())) :: term() | :noop
  def guard_shared_write(fun) when is_function(fun, 0) do
    if draining?(), do: :noop, else: fun.()
  catch
    :exit, _ -> fun.()
  end

  @spec connection_count() :: integer()
  def connection_count do
    GenServer.call(__MODULE__, :connection_count)
  end

  @doc false
  def reset_for_test! do
    GenServer.call(__MODULE__, :reset_for_test)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    state = %{
      count: 0,
      draining: false,
      grace_ref: nil,
      hard_ref: nil,
      auto_ref: nil,
      monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:track, pid}, state) do
    ref = Process.monitor(pid)
    monitors = Map.put(state.monitors, ref, pid)
    {:noreply, %{state | count: state.count + 1, monitors: monitors}}
  end

  @impl true
  def handle_call({:start_drain, _}, _from, %{draining: true} = state) do
    {:reply, {:error, :already_draining}, state}
  end

  def handle_call({:start_drain, commits_behind}, _from, state) do
    try do
      Casein.Deployment.Registry.mark_draining()
    rescue
      _ -> :ok
    end

    version =
      try do
        Casein.Deployment.Registry.version()
      rescue
        _ -> "unknown"
      end

    Phoenix.PubSub.broadcast(
      Casein.PubSub,
      "deploy:updates",
      {:update_available, version, commits_behind}
    )

    hard_ref = Process.send_after(self(), :hard_timeout, @hard_ms)
    auto_ref = Process.send_after(self(), :auto_reconnect, @auto_reconnect_ms)

    state = %{state | draining: true, hard_ref: hard_ref, auto_ref: auto_ref}
    state = if state.count == 0, do: maybe_start_grace(state), else: state

    {:reply, :ok, state}
  end

  def handle_call(:draining?, _from, state) do
    {:reply, state.draining, state}
  end

  def handle_call(:connection_count, _from, state) do
    {:reply, state.count, state}
  end

  def handle_call(:reset_for_test, _from, state) do
    for ref <- [state.grace_ref, state.hard_ref, state.auto_ref],
        ref,
        do: Process.cancel_timer(ref)

    {:reply, :ok,
     %{
       count: 0,
       draining: false,
       grace_ref: nil,
       hard_ref: nil,
       auto_ref: nil,
       monitors: %{}
     }}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    monitors = Map.delete(state.monitors, ref)
    count = max(0, state.count - 1)
    state = %{state | count: count, monitors: monitors}

    state = if state.draining and count == 0, do: maybe_start_grace(state), else: state

    {:noreply, state}
  end

  def handle_info(:grace_timeout, %{count: 0, draining: true} = state) do
    stop_system(0)
    {:noreply, state}
  end

  def handle_info(:grace_timeout, state) do
    {:noreply, %{state | grace_ref: nil}}
  end

  def handle_info(:hard_timeout, %{draining: true} = state) do
    stop_system(0)
    {:noreply, state}
  end

  def handle_info(:hard_timeout, state) do
    {:noreply, %{state | hard_ref: nil}}
  end

  # Clients didn't move off this draining node on their own. Nudge the ones
  # still attached to reconnect: a background LiveSocket reconnect re-dials the
  # current.sock symlink onto the live instance (silent for code-only deploys),
  # letting this node drain to zero and stop via the grace path rather than
  # waiting out the hard timeout. No-op once connections have already drained.
  def handle_info(:auto_reconnect, %{draining: true, count: count} = state) when count > 0 do
    Phoenix.PubSub.broadcast(Casein.PubSub, "deploy:updates", {:deploy_reconnect})
    {:noreply, %{state | auto_ref: nil}}
  end

  def handle_info(:auto_reconnect, state) do
    {:noreply, %{state | auto_ref: nil}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Seam for tests: a drain armed by a test must never stop the test VM.
  # Drain is a real singleton in the app tree, so a 3s grace timeout from a
  # drain test fires mid-suite and System.stop(0) shuts ExUnit down silently
  # (truncated runs, exit 0). test_helper.exs injects a no-op.
  defp stop_system(status) do
    case Application.get_env(:casein, :drain_stop_system) do
      fun when is_function(fun, 1) -> fun.(status)
      nil -> System.stop(status)
    end
  end

  defp maybe_start_grace(%{grace_ref: nil} = state) do
    ref = Process.send_after(self(), :grace_timeout, @grace_ms)
    %{state | grace_ref: ref}
  end

  defp maybe_start_grace(state), do: state
end
