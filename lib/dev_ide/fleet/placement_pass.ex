defmodule DevIDE.Fleet.PlacementPass do
  @moduledoc """
  Periodic placement pass: dequeue pending assignments and attempt
  deterministic placement against the current fleet topology.

  ## Flow

    1. Peek at the next queued assignment.
    2. Compute eligible runners via `Placement.compute_eligible/2`.
    3. Choose one via `Policy.choose/3`.
    4. If chosen, acquire lease via `Fleet.acquire_lease/3`.
    5. If no eligible, leave assignment in queue (try next).

  The pass is idempotent: running it twice with no fleet changes
  produces the same result.  It is also safe to run concurrently
  with queue mutations — the GenServer serializes.

  ## Triggering

  Placement passes can be triggered by:

    * Periodic timer (default every 5s)
    * Explicit `trigger/0` call
    * Fleet events (runner heartbeat, lease release)

  ## Determinism

  Given identical fleet state and identical queue contents, the
  placement result is always the same.  This enables:

    * reproducible debugging
    * deterministic replay
    * auditability
  """

  use GenServer

  alias DevIDE.Fleet
  alias DevIDE.Fleet.{Placement, Policy, Queue}

  @default_interval_ms 5_000

  ## Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Manually trigger a placement pass."
  @spec trigger() :: :ok
  def trigger, do: GenServer.call(__MODULE__, :run_pass)

  @doc "Return the results of the last placement pass."
  @spec last_result() :: map()
  def last_result, do: GenServer.call(__MODULE__, :last_result)

  ## Callbacks

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, default_interval_ms())
    schedule_tick(interval)
    {:ok, %{interval_ms: interval, last_result: empty_result()}}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    result = run_placement_pass()
    schedule_tick(state.interval_ms)
    {:noreply, %{state | last_result: result}}
  end

  @impl GenServer
  def handle_call(:run_pass, _from, state) do
    result = run_placement_pass()
    {:reply, :ok, %{state | last_result: result}}
  end

  def handle_call(:last_result, _from, state) do
    {:reply, state.last_result, state}
  end

  ## Internal — placement pass

  defp run_placement_pass do
    snapshot = enrich_snapshot(Fleet.snapshot())
    result = do_pass(snapshot, %{placed: [], skipped: [], failed: []}, 100)

    %{
      timestamp: DateTime.utc_now(),
      total_attempted: length(result.placed) + length(result.skipped) + length(result.failed),
      placed: Enum.reverse(result.placed),
      skipped: Enum.reverse(result.skipped),
      failed: Enum.reverse(result.failed)
    }
  end

  defp do_pass(_snapshot, result, 0), do: result

  defp do_pass(_snapshot, result, remaining) do
    case Queue.peek() do
      nil ->
        result

      entry ->
        snapshot = enrich_snapshot(Fleet.snapshot())

        case attempt_placement(entry, snapshot) do
          {:placed, placed} ->
            do_pass(snapshot, %{result | placed: [placed | result.placed]}, remaining - 1)

          {:skip, reason} ->
            # No eligible runners for this entry — stop the pass.
            # The entry remains at the front of the queue for next time.
            %{result | skipped: [reason | result.skipped]}

          {:failed, failed} ->
            # Lease acquisition failed — fleet state has changed.
            # Stop the pass; next tick will retry with fresh state.
            %{result | failed: [failed | result.failed]}
        end
    end
  end

  defp attempt_placement(entry, snapshot) do
    eligible = Placement.compute_eligible(entry.requirements, snapshot)

    if eligible == [] do
      # No eligible runners — skip this entry, try next
      {:skip, "no_eligible"}
    else
      chosen = Policy.choose(eligible, :first)

      case Fleet.acquire_lease(chosen, entry.assignment_id,
             duration_ms: entry.requirements.max_runtime_ms || default_lease_duration_ms()
           ) do
        {:ok, lease} ->
          Queue.remove(entry.assignment_id)

          {:placed,
           %{
             assignment_id: entry.assignment_id,
             runner_id: chosen,
             lease_id: lease.id,
             requirements: entry.requirements
           }}

        {:error, reason} ->
          # Lease acquisition failed (runner went busy, etc.)
          # Leave in queue, try next
          {:failed,
           %{
             assignment_id: entry.assignment_id,
             runner_id: chosen,
             error: reason,
             requirements: entry.requirements
           }}
      end
    end
  end

  defp enrich_snapshot(snapshot) do
    Map.merge(snapshot, Fleet.scheduling_snapshot())
  end

  defp empty_result do
    %{
      timestamp: nil,
      total_attempted: 0,
      placed: [],
      skipped: [],
      failed: []
    }
  end

  defp schedule_tick(interval), do: Process.send_after(self(), :tick, interval)

  defp default_interval_ms do
    Application.get_env(:dev_ide, :fleet_placement_interval_ms, @default_interval_ms)
  end

  defp default_lease_duration_ms do
    Application.get_env(:dev_ide, :fleet_lease_duration_ms, 15 * 60 * 1000)
  end
end
