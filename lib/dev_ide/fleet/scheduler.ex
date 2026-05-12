defmodule DevIDE.Fleet.Scheduler do
  @moduledoc """
  Read-only scheduling planner for fleet balancing and prioritization.
  """

  alias DevIDE.Fleet
  alias DevIDE.Fleet.Placement
  alias DevIDE.Fleet.Queue

  @spec plan(keyword()) :: map()
  def plan(_opts \\ []) do
    snapshot = Fleet.scheduling_snapshot()

    entries =
      Queue.list()
      |> Enum.map(fn entry ->
        eligible = Placement.compute_eligible(entry.requirements, snapshot)

        %{
          assignment_id: entry.assignment_id,
          priority: entry.requirements.priority,
          concurrency_group: entry.requirements.concurrency_group,
          runner_pool: entry.requirements.runner_pool,
          workspace_affinity: entry.requirements.workspace_affinity,
          eligible_runners: eligible,
          selected_runner: List.first(eligible)
        }
      end)

    %{
      generated_at: DateTime.utc_now(),
      queue_depth: length(entries),
      active_leases: length(snapshot.active_leases),
      active_concurrency_groups: snapshot.active_concurrency_groups,
      runner_pools: runner_pools(snapshot.runners),
      last_placement: Fleet.PlacementPass.last_result(),
      entries: entries
    }
  end

  defp runner_pools(runners) do
    runners
    |> Enum.group_by(fn runner ->
      metadata = runner.metadata || %{}
      Map.get(metadata, "pool") || Map.get(metadata, :pool) || "default"
    end)
    |> Map.new(fn {pool, pool_runners} -> {pool, Enum.map(pool_runners, & &1.id)} end)
  end
end
