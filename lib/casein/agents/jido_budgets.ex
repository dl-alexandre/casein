defmodule Casein.Agents.JidoBudgets do
  @moduledoc """
  Workspace and fleet resource budgets for headless Jido workers (#1018).

  Consumes the #1014 pod admit/queue/cancel contract. Exceeding a budget
  queues or rejects with an honest reason. One workspace cannot take the
  whole fleet. Metrics never persist prompts, source, secrets, or output.
  """

  alias Casein.Agents.Activity
  alias Casein.Agents.JidoBudgets.{Benchmark, Decision, Ledger, Limits, Sampler, Verdict}
  alias Casein.Agents.JidoPod
  alias Casein.Agents.JidoPod.{Fleet, Metrics}

  @type reason :: Decision.reason()

  @spec limits() :: map()
  def limits, do: Limits.public()

  @spec snapshot() :: map()
  def snapshot do
    host = Sampler.snapshot()
    Ledger.sample_host(host)
    ledger = Ledger.snapshot()
    fleet = Fleet.snapshot()

    %{
      limits: limits(),
      fleet: fleet,
      ledger: ledger,
      host: host,
      process_count: host.process_count,
      memory_bytes: host.memory_bytes,
      rss_bytes: host.rss_bytes,
      cpu_ratio: host.cpu_ratio,
      backpressure: backpressure(ledger)
    }
  end

  @spec snapshot(String.t()) :: map()
  def snapshot(workspace_id) when is_binary(workspace_id) do
    pod =
      try do
        JidoPod.snapshot(workspace_id).pod
      rescue
        _ -> %{workspace_id: workspace_id, running: 0, queued: 0}
      end

    Map.merge(snapshot(), %{
      workspace_id: workspace_id,
      pod: pod,
      last_decision: Ledger.last_decision(workspace_id)
    })
  end

  @spec last_decision(String.t()) :: map() | nil
  def last_decision(workspace_id), do: Ledger.last_decision(workspace_id)

  @spec decide(map()) :: Decision.t()
  def decide(usage), do: Decision.decide(usage)

  @spec usage(String.t()) :: map()
  def usage(workspace_id) when is_binary(workspace_id) do
    pod =
      try do
        JidoPod.snapshot(workspace_id).pod
      rescue
        _ -> %{running: 0, queued: 0, draining?: false}
      end

    usage_from(workspace_id, pod)
  end

  @spec usage_from(String.t(), map()) :: map()
  def usage_from(workspace_id, pod) when is_binary(workspace_id) and is_map(pod) do
    fleet = Fleet.snapshot()
    ledger = Ledger.snapshot()
    host = Sampler.snapshot()

    %{
      running: Map.get(pod, :running, 0),
      queued: Map.get(pod, :queued, 0),
      draining?: Map.get(pod, :draining?, false),
      workspace_running: Map.get(fleet.running, workspace_id, 0),
      fleet_running: fleet.fleet_running,
      fairness?: workspace_id in fleet.waiters and Map.get(fleet.running, workspace_id, 0) > 0,
      provider_inflight: ledger.provider_inflight,
      fleet_memory_bytes: ledger.fleet_memory_bytes,
      crash_count: ledger.crash_count,
      leaked_leases: ledger.leaked_leases,
      cpu_pressure?: host.status == "constrained" and cpu_pressure?(host),
      rss_pressure?: host.status == "constrained" and rss_pressure?(host)
    }
  end

  @spec precheck(String.t()) :: :ok | {:queue, reason()} | {:reject, reason()}
  def precheck(workspace_id) when is_binary(workspace_id) do
    case decide(usage(workspace_id)) do
      :admit -> :ok
      other -> other
    end
  end

  @spec precheck_from(String.t(), map()) :: :ok | {:queue, reason()} | {:reject, reason()}
  def precheck_from(workspace_id, pod) when is_binary(workspace_id) and is_map(pod) do
    case decide(usage_from(workspace_id, pod)) do
      :admit -> :ok
      other -> other
    end
  end

  @spec record(String.t(), :admit | :queue | :reject | :drain, atom(), map()) :: :ok
  def record(workspace_id, action, reason, extra \\ %{}) do
    extra = safe_extra(extra)
    Ledger.record_decision(workspace_id, action, reason, extra)
    observe_activity(workspace_id, action, reason, extra)
    :ok
  end

  defp safe_extra(extra) when is_map(extra) do
    Map.take(extra, [
      :running,
      :queued,
      :fleet_running,
      :provider_inflight,
      :memory_bytes,
      :crash_count,
      :leaked_leases,
      :queue_depth,
      :drained
    ])
  end

  defp safe_extra(_), do: %{}

  @spec try_provider(String.t()) :: :ok | {:error, :provider_limit}
  defdelegate try_provider(attempt_id), to: Ledger

  @spec release_provider(String.t()) :: :ok
  defdelegate release_provider(attempt_id), to: Ledger

  @spec charge_memory(String.t(), String.t(), term()) :: :ok | {:error, :memory_limit}
  def charge_memory(workspace_id, attempt_id, term) do
    bytes = byte_size_of(term)

    if bytes > Limits.get(:max_action_output_bytes) do
      {:error, :memory_limit}
    else
      Ledger.charge_memory(workspace_id, attempt_id, bytes)
    end
  end

  @spec release_memory(String.t()) :: :ok
  defdelegate release_memory(attempt_id), to: Ledger

  @spec acquire_lease(String.t(), String.t()) :: :ok
  defdelegate acquire_lease(workspace_id, attempt_id), to: Ledger

  @spec release_lease(String.t()) :: :ok
  defdelegate release_lease(attempt_id), to: Ledger

  @spec crash(String.t()) :: :ok
  defdelegate crash(workspace_id), to: Ledger

  @spec record_admission(non_neg_integer()) :: :ok
  defdelegate record_admission(latency_ms), to: Ledger

  @spec byte_size_of(term()) :: non_neg_integer()
  def byte_size_of(term) do
    :erlang.external_size(term)
  rescue
    _ -> 0
  end

  @spec maybe_drain(String.t()) :: :ok | {:ok, [map()]}
  def maybe_drain(workspace_id) when is_binary(workspace_id) do
    usage = usage(workspace_id)

    if usage.cpu_pressure? or usage.rss_pressure? do
      reason = if usage.cpu_pressure?, do: :cpu_pressure, else: :rss_pressure
      result = JidoPod.drain(workspace_id)
      record(workspace_id, :drain, reason, %{drained: true})
      result
    else
      :ok
    end
  end

  @spec benchmark(keyword()) :: map()
  defdelegate benchmark(opts \\ []), to: Benchmark, as: :run

  @spec verdict(map()) :: map()
  defdelegate verdict(report), to: Verdict, as: :evaluate

  @spec reset() :: :ok
  def reset, do: Ledger.reset()

  defp backpressure(ledger) do
    ledger.last_decisions
    |> Enum.filter(fn {_ws, entry} -> entry.action in [:queue, :reject, :drain] end)
    |> Enum.map(fn {ws, entry} ->
      %{
        workspace_id: ws,
        action: entry.action,
        reason: entry.reason,
        at: entry.at
      }
    end)
  end

  defp cpu_pressure?(%{cpu_ratio: ratio}) when is_float(ratio) do
    ratio >= Limits.get(:cpu_pressure_ratio)
  end

  defp cpu_pressure?(_), do: false

  defp rss_pressure?(%{status: "constrained", reasons: reasons}) do
    Enum.any?(reasons, &String.contains?(&1, "memory"))
  end

  defp rss_pressure?(_), do: false

  defp observe_activity(workspace_id, action, reason, extra) do
    status = if action == :reject, do: :error, else: :ok

    _ =
      Activity.record(%{
        workspace_id: workspace_id,
        source: :jido_budgets,
        tool: "jido_budgets",
        summary: "budget #{action} #{reason}",
        metadata: %{
          action: action,
          reason: reason,
          extra: extra,
          headless: true
        },
        status: status
      })

    Metrics.inc(metric_name(action, reason))
    Metrics.emit(:budget, %{count: 1}, %{action: action, reason: reason})
    :ok
  rescue
    _ -> :ok
  end

  defp metric_name(:reject, :queue_full), do: :rejected
  defp metric_name(:reject, _), do: :rejected
  defp metric_name(:queue, _), do: :queued
  defp metric_name(_, _), do: :admitted
end
