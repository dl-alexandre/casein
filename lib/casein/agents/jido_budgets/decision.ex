defmodule Casein.Agents.JidoBudgets.Decision do
  @moduledoc """
  Pure admit/queue/reject decision for Jido resource budgets.
  """

  alias Casein.Agents.JidoBudgets.Limits

  @type reason ::
          :ok
          | :workspace_limit
          | :queue_full
          | :fleet_limit
          | :fairness
          | :workspace_share
          | :provider_limit
          | :memory_limit
          | :crash_rate
          | :lease_leak
          | :rss_pressure
          | :cpu_pressure
          | :draining

  @type t :: :admit | {:queue, reason()} | {:reject, reason()}

  @spec decide(map()) :: t()
  def decide(usage) when is_map(usage) do
    cond do
      truthy?(usage[:draining?]) ->
        {:reject, :draining}

      pressure_reason(usage) ->
        pressure_verdict(usage)

      crash_rate?(usage) ->
        {:reject, :crash_rate}

      lease_leak?(usage) ->
        {:reject, :lease_leak}

      memory_limit?(usage) ->
        {:reject, :memory_limit}

      over?(usage[:running], Limits.get(:max_running_per_workspace)) ->
        queue_or_reject(usage, :workspace_limit)

      over?(usage[:workspace_running], Limits.max_workspace_share()) ->
        queue_or_reject(usage, :workspace_share)

      over?(usage[:fleet_running], Limits.get(:max_running_fleet)) ->
        queue_or_reject(usage, :fleet_limit)

      usage[:fairness?] == true ->
        queue_or_reject(usage, :fairness)

      over?(usage[:provider_inflight], Limits.get(:max_provider_inflight)) ->
        queue_or_reject(usage, :provider_limit)

      true ->
        :admit
    end
  end

  @spec queue_or_reject(map(), reason()) :: {:queue, reason()} | {:reject, reason()}
  def queue_or_reject(usage, reason) do
    queued = usage[:queued] || 0

    if queued < Limits.get(:max_queued_per_workspace) do
      {:queue, reason}
    else
      {:reject, if(reason == :workspace_limit, do: :queue_full, else: reason)}
    end
  end

  defp pressure_reason(usage) do
    cond do
      usage[:cpu_pressure?] == true -> :cpu_pressure
      usage[:rss_pressure?] == true -> :rss_pressure
      true -> nil
    end
  end

  defp pressure_verdict(usage) do
    {:reject, pressure_reason(usage)}
  end

  defp crash_rate?(usage) do
    (usage[:crash_count] || 0) > Limits.get(:max_crash_rate)
  end

  defp lease_leak?(usage) do
    (usage[:leaked_leases] || 0) > Limits.get(:max_leaked_leases)
  end

  defp memory_limit?(usage) do
    bytes = usage[:fleet_memory_bytes] || 0
    bytes > Limits.get(:max_fleet_memory_bytes)
  end

  defp over?(nil, _max), do: false
  defp over?(value, max) when is_integer(value) and is_integer(max), do: value >= max
  defp over?(_, _), do: false

  defp truthy?(true), do: true
  defp truthy?(_), do: false
end
