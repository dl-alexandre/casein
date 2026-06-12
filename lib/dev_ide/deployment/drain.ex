defmodule DevIDE.Deployment.Drain do
  @moduledoc """
  Counts active LiveView connections and coordinates graceful shutdown
  when a deploy drain is initiated.

  On drain start, broadcasts an update-available notice over PubSub and
  waits for connections to drop to zero before stopping the VM. A hard
  timeout ensures the node eventually exits even if connections never
  fully close.
  """

  use GenServer

  @grace_ms 5_000
  @hard_ms 1_800_000

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

  @spec connection_count() :: integer()
  def connection_count do
    GenServer.call(__MODULE__, :connection_count)
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
      DevIDE.Deployment.Registry.mark_draining()
    rescue
      _ -> :ok
    end

    version =
      try do
        DevIDE.Deployment.Registry.version()
      rescue
        _ -> "unknown"
      end

    Phoenix.PubSub.broadcast(
      DevIde.PubSub,
      "deploy:updates",
      {:update_available, version, commits_behind}
    )

    hard_ref = Process.send_after(self(), :hard_timeout, @hard_ms)

    state = %{state | draining: true, hard_ref: hard_ref}
    state = if state.count == 0, do: maybe_start_grace(state), else: state

    {:reply, :ok, state}
  end

  def handle_call(:draining?, _from, state) do
    {:reply, state.draining, state}
  end

  def handle_call(:connection_count, _from, state) do
    {:reply, state.count, state}
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
    System.stop(0)
    {:noreply, state}
  end

  def handle_info(:grace_timeout, state) do
    {:noreply, %{state | grace_ref: nil}}
  end

  def handle_info(:hard_timeout, %{draining: true} = state) do
    System.stop(0)
    {:noreply, state}
  end

  def handle_info(:hard_timeout, state) do
    {:noreply, %{state | hard_ref: nil}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_start_grace(%{grace_ref: nil} = state) do
    ref = Process.send_after(self(), :grace_timeout, @grace_ms)
    %{state | grace_ref: ref}
  end

  defp maybe_start_grace(state), do: state
end
