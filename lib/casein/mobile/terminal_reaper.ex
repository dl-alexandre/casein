defmodule Casein.Mobile.TerminalReaper do
  @moduledoc "Retries exact teardown for expired and interrupted mobile terminal leases."

  use GenServer
  require Logger

  @interval_ms 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = %{interval: Keyword.get(opts, :interval, @interval_ms)}
    send(self(), :startup_reconcile)
    {:ok, state}
  end

  @impl true
  def handle_info(:startup_reconcile, state) do
    _ = safe_reconcile(&Casein.Mobile.TerminalSessions.reconcile_due/0)
    _ = safe_reconcile(&Casein.Mobile.TerminalSessions.reconcile_startup/0)
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(:reap, state) do
    _ = safe_reconcile(&Casein.Mobile.TerminalSessions.reconcile_due/0)
    schedule(state.interval)
    {:noreply, state}
  end

  defp safe_reconcile(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("mobile terminal reconciliation failed", reason: Exception.message(error))
      {:error, error}
  catch
    :exit, reason ->
      Logger.warning("mobile terminal reconciliation exited", reason: inspect(reason, limit: 3))
      {:error, reason}
  end

  defp schedule(interval), do: Process.send_after(self(), :reap, interval)
end
