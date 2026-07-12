defmodule DevIDE.Deployment.PollerWatcher do
  @moduledoc """
  Periodically reads the deploy-poller status file and broadcasts UI updates.

  Drift is checked once on boot; poller status can change while the release keeps
  running (gate failure, in-progress build), so this GenServer polls on an interval.
  """

  use GenServer

  alias DevIDE.Deployment.LastDeploy

  @default_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    if watcher_enabled?() do
      interval_ms =
        Keyword.get(opts, :interval_ms, config(:poller_watch_interval_ms, @default_interval_ms))

      send(self(), :tick)
      {:ok, %{interval_ms: interval_ms, last_status: nil}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:tick, %{interval_ms: interval_ms} = state) do
    status = LastDeploy.check_and_broadcast()
    _ = Process.send_after(self(), :tick, interval_ms)
    {:noreply, %{state | last_status: status}}
  end

  defp watcher_enabled? do
    DevIDE.Deployment.Capabilities.enabled?(:poller) and
      System.get_env("DEV_IDE_DEPLOY_POLLER_WATCH") not in ["0", "false", "no"]
  end

  defp config(key, default) do
    :dev_ide
    |> Application.get_env(:deployment, [])
    |> Keyword.get(key, default)
  end
end
