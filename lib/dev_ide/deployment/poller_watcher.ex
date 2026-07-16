defmodule DevIDE.Deployment.PollerWatcher do
  @moduledoc """
  Periodically reads the deploy-poller status file and broadcasts UI updates.

  Poller status can change while the release keeps running (gate failure,
  in-progress build), so this GenServer polls on an interval. Each tick also
  re-checks drift (cheap — `Drift.remote_head/1` is cached for 60s) so drift
  transitions are actually observed instead of only at boot, and feeds both
  observations to `DevIDE.Deployment.DeployAudit`, which persists audit rows
  on transitions only.
  """

  use GenServer

  alias DevIDE.Deployment.{DeployAudit, Drift, LastDeploy}

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
      {:ok, %{interval_ms: interval_ms, last_status: nil, audit: DeployAudit.new()}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:tick, %{interval_ms: interval_ms} = state) do
    status = LastDeploy.check_and_broadcast()
    drift = if Drift.enabled?(), do: Drift.check_and_broadcast(log: false), else: nil
    audit = DeployAudit.observe(state.audit, read_record(), drift)

    _ = Process.send_after(self(), :tick, interval_ms)
    {:noreply, %{state | last_status: status, audit: audit}}
  end

  defp read_record do
    case LastDeploy.read() do
      {:ok, record} -> record
      _ -> nil
    end
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
