defmodule DevIDE.Fleet.Placement do
  @moduledoc """
  Deterministic placement computation.

  Given `AssignmentRequirements` and a fleet snapshot, returns a
  reproducible, ordered list of eligible runner IDs.

  ## Determinism guarantee

  The same `requirements` + the same `fleet_snapshot` always
  produces the same ordered result.  This is achieved by:

    1. Filtering with pure boolean predicates (no randomness)
    2. Sorting by `:registered_at` then `:id` (stable ordering)

  ## Eligibility rules

    * Runner must be `:idle` or `:online` (not `:busy`, `:offline`, `:draining`)
    * Runner must possess all required `:capabilities`
    * Runner must not be in `:anti_affinity`
    * Runner must be in the requested runner pool, when one is set
    * Concurrency group limits must not already be saturated
    * If `:isolation` is `:dedicated`, runner must have no active leases
    * Workspace affinity is a preference, not a hard constraint (sorted first)
  """

  alias DevIDE.Fleet.AssignmentRequirements

  @type fleet_snapshot :: map()

  @doc """
  Compute the ordered list of eligible runner IDs for an assignment.

  Returns `[]` when no runner matches the requirements.
  """
  @spec compute_eligible(AssignmentRequirements.t(), fleet_snapshot()) :: [String.t()]
  def compute_eligible(%AssignmentRequirements{} = requirements, fleet_snapshot) do
    runners = Map.get(fleet_snapshot, :runners, [])

    runners
    |> Enum.filter(&eligible?(&1, requirements, fleet_snapshot))
    |> sort_candidates(requirements)
    |> Enum.map(& &1.id)
  end

  @doc """
  Returns the first eligible runner, or `nil` if none match.

  This is the deterministic "choice" — always the first in the
  sorted eligible list.
  """
  @spec first_eligible(AssignmentRequirements.t(), fleet_snapshot()) :: String.t() | nil
  def first_eligible(requirements, fleet_snapshot) do
    case compute_eligible(requirements, fleet_snapshot) do
      [] -> nil
      [first | _] -> first
    end
  end

  @doc """
  Check if a single runner is eligible for an assignment.

  Used for targeted placement (e.g. "can runner-1 take assignment-2?").
  """
  @spec runner_eligible?(map(), AssignmentRequirements.t(), fleet_snapshot()) :: boolean()
  def runner_eligible?(runner, requirements, fleet_snapshot) do
    eligible?(runner, requirements, fleet_snapshot)
  end

  ## Internal — eligibility predicates

  defp eligible?(runner, requirements, fleet_snapshot) do
    runnable?(runner) and
      capabilities_met?(runner, requirements) and
      not_anti_affinity?(runner, requirements) and
      runner_pool_met?(runner, requirements) and
      concurrency_group_available?(requirements, fleet_snapshot) and
      isolation_met?(runner, requirements, fleet_snapshot)
  end

  defp runnable?(runner) do
    runner.state in [:idle, :online]
  end

  defp capabilities_met?(runner, requirements) do
    required = requirements.capabilities
    available = runner.capabilities || []
    Enum.all?(required, &(&1 in available))
  end

  defp not_anti_affinity?(runner, requirements) do
    runner.id not in requirements.anti_affinity
  end

  defp runner_pool_met?(_runner, %{runner_pool: pool}) when pool in [nil, ""], do: true

  defp runner_pool_met?(runner, %{runner_pool: pool}) do
    metadata = runner.metadata || %{}

    Map.get(metadata, "pool") == pool or Map.get(metadata, :pool) == pool or
      "pool:#{pool}" in (runner.capabilities || [])
  end

  defp concurrency_group_available?(%{concurrency_group: group}, _snapshot)
       when group in [nil, ""],
       do: true

  defp concurrency_group_available?(requirements, snapshot) do
    limit = requirements.concurrency_limit || 1
    active = Map.get(snapshot, :active_concurrency_groups, %{})
    Map.get(active, requirements.concurrency_group, 0) < limit
  end

  defp isolation_met?(runner, requirements, fleet_snapshot) do
    if requirements.isolation == :dedicated do
      active_for_runner = Map.get(fleet_snapshot, :active_leases_by_runner, %{})[runner.id] || []
      active_for_runner == []
    else
      true
    end
  end

  ## Internal — deterministic sorting

  defp sort_candidates(runners, requirements) do
    # Deterministic ordering: workspace affinity first, then earlier
    # registration, then lexicographic id.
    Enum.sort(runners, fn a, b ->
      a_affinity = affinity_score(a, requirements)
      b_affinity = affinity_score(b, requirements)
      a_time = a.registered_at || DateTime.utc_now()
      b_time = b.registered_at || DateTime.utc_now()

      cond do
        a_affinity != b_affinity ->
          a_affinity > b_affinity

        true ->
          case DateTime.compare(a_time, b_time) do
            :lt -> true
            :gt -> false
            :eq -> a.id <= b.id
          end
      end
    end)
  end

  defp affinity_score(_runner, %{workspace_affinity: workspace_id})
       when workspace_id in [nil, ""],
       do: 0

  defp affinity_score(runner, %{workspace_affinity: workspace_id}) do
    workspaces =
      Map.get(runner.metadata || %{}, "workspaces") ||
        Map.get(runner.metadata || %{}, :workspaces) || []

    if workspace_id in workspaces, do: 1, else: 0
  end
end
