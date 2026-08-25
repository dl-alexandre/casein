defmodule Casein.Agents.JidoBudgets.Verdict do
  @moduledoc """
  Numeric go/no-go and rollback trigger for the Jido vs OpenCode benchmark.
  """

  alias Casein.Agents.JidoBudgets.Limits

  @spec evaluate(map()) :: map()
  def evaluate(report) when is_map(report) do
    thresholds = %{
      go_process_ratio: Limits.get(:go_process_ratio),
      go_rss_ratio: Limits.get(:go_rss_ratio),
      go_max_error_rate: Limits.get(:go_max_error_rate),
      rollback_process_ratio: Limits.get(:rollback_process_ratio),
      rollback_leaked_leases: Limits.get(:max_leaked_leases)
    }

    checks = [
      check_process(report, thresholds),
      check_rss(report, thresholds),
      check_errors(report, thresholds),
      check_cancel(report),
      check_contention(report),
      check_leaks(report, thresholds)
    ]

    rollback = Enum.find(checks, & &1.rollback)

    %{
      go?: Enum.all?(checks, & &1.pass),
      rollback?: match?(%{rollback: true}, rollback),
      rollback_trigger: rollback && rollback.name,
      thresholds: thresholds,
      checks: checks
    }
  end

  defp check_process(report, thresholds) do
    ratio = ratio(get_in(report, [:comparison, :process_ratio]))
    limit = thresholds.go_process_ratio
    rollback_at = thresholds.rollback_process_ratio

    %{
      name: :process_ratio,
      value: ratio,
      limit: limit,
      pass: is_number(ratio) and ratio < limit,
      rollback: is_number(ratio) and ratio >= rollback_at,
      note: "Jido process delta / documented OpenCode process count"
    }
  end

  defp check_rss(report, thresholds) do
    ratio = ratio(get_in(report, [:comparison, :rss_ratio]))
    limit = thresholds.go_rss_ratio

    %{
      name: :rss_ratio,
      value: ratio,
      limit: limit,
      pass: is_number(ratio) and ratio < limit,
      rollback: false,
      note: "Jido RSS delta / documented OpenCode RSS"
    }
  end

  defp check_errors(report, thresholds) do
    rate = ratio(get_in(report, [:comparison, :error_rate]))
    limit = thresholds.go_max_error_rate

    %{
      name: :error_rate,
      value: rate,
      limit: limit,
      pass: is_number(rate) and rate <= limit,
      rollback: is_number(rate) and rate > limit,
      note: "failed+provider_unavailable / completed+failed on burst"
    }
  end

  defp check_cancel(report) do
    cancelled = get_in(report, [:scenarios, :cancel, :cancelled]) || 0
    requested = get_in(report, [:scenarios, :cancel, :requested]) || 0
    pass = requested > 0 and cancelled == requested

    %{
      name: :cancellation,
      value: cancelled,
      limit: requested,
      pass: pass,
      rollback: requested > 0 and not pass,
      note: "every cancelled attempt reaches cancelled"
    }
  end

  defp check_contention(report) do
    both = get_in(report, [:scenarios, :contention, :both_workspaces_ran]) == true

    %{
      name: :workspace_fairness,
      value: both,
      limit: true,
      pass: both,
      rollback: not both,
      note: "one workspace cannot consume the fleet"
    }
  end

  defp check_leaks(report, thresholds) do
    leaked = get_in(report, [:comparison, :leaked_leases]) || 0
    limit = thresholds.rollback_leaked_leases

    %{
      name: :leaked_leases,
      value: leaked,
      limit: limit,
      pass: leaked <= limit,
      rollback: leaked > limit,
      note: "leases acquired must be released"
    }
  end

  defp ratio(value) when is_number(value), do: value
  defp ratio(_), do: nil
end
