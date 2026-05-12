defmodule DevIDE.Assignments.Replay do
  @moduledoc """
  Deterministic startup replay: rebuild all projections from persisted events.

  Supports two modes of operation:

    * **Verify** (default) — compare cached projections against replayed
      projections and report mismatches without writing anything.
    * **Repair** — overwrite the projection cache with freshly reduced
      projections.

  Called once at application boot (after EventStore and ProjectionStore
  are up).  Safe to call repeatedly — `repair` is idempotent.
  """

  alias DevIDE.Assignments.Assignment
  alias DevIDE.Assignments.EventStore
  alias DevIDE.Assignments.ProjectionStore
  alias DevIDE.Assignments.Reducer

  @type verify_status :: :consistent | :inconsistent | :missing

  @type verify_result :: %{
          assignment_id: String.t(),
          status: verify_status(),
          event_count: non_neg_integer(),
          from_events: Assignment.t() | nil,
          from_cache: Assignment.t() | nil
        }

  @type verify_report :: %{
          total: non_neg_integer(),
          consistent: non_neg_integer(),
          inconsistent: non_neg_integer(),
          missing: non_neg_integer(),
          details: [verify_result()]
        }

  ## Verification (read-only)

  @doc """
  Verify every assignment stream against its cached projection.

  Returns a report showing consistent, inconsistent, and missing entries.
  Does **not** mutate the projection cache.
  """
  @spec verify_all() :: verify_report()
  def verify_all do
    event_store = resolve_event_store()
    projection_store = resolve_projection_store()

    all_events = event_store.list_events()

    if all_events == [] do
      %{
        total: 0,
        consistent: 0,
        inconsistent: 0,
        missing: 0,
        details: []
      }
    else
      events_by_assignment = Enum.group_by(all_events, & &1.assignment_id)
      cached_projections = projection_store.list()
      cached_by_id = Map.new(cached_projections, &{&1.id, &1})

      details =
        Enum.map(events_by_assignment, fn {assignment_id, events} ->
          from_events = Reducer.reduce(events)
          from_cache = Map.get(cached_by_id, assignment_id)

          status =
            cond do
              is_nil(from_cache) -> :missing
              from_events == from_cache -> :consistent
              true -> :inconsistent
            end

          %{
            assignment_id: assignment_id,
            status: status,
            event_count: length(events),
            from_events: from_events,
            from_cache: from_cache
          }
        end)

      %{
        total: length(details),
        consistent: Enum.count(details, &(&1.status == :consistent)),
        inconsistent: Enum.count(details, &(&1.status == :inconsistent)),
        missing: Enum.count(details, &(&1.status == :missing)),
        details: details
      }
    end
  end

  @doc """
  Verify a single assignment stream against its cached projection.

  Returns `{:error, :no_events}` if the assignment has no event stream.
  """
  @spec verify(String.t()) :: {:ok, verify_result()} | {:error, :no_events}
  def verify(assignment_id) do
    event_store = resolve_event_store()
    projection_store = resolve_projection_store()

    events = event_store.events_for(assignment_id)

    if events == [] do
      {:error, :no_events}
    else
      from_events = Reducer.reduce(events)

      from_cache =
        case projection_store.get(assignment_id) do
          {:ok, p} -> p
          :error -> nil
        end

      status =
        cond do
          is_nil(from_cache) -> :missing
          from_events == from_cache -> :consistent
          true -> :inconsistent
        end

      {:ok,
       %{
         assignment_id: assignment_id,
         status: status,
         event_count: length(events),
         from_events: from_events,
         from_cache: from_cache
       }}
    end
  end

  ## Repair (mutating)

  @doc """
  Rebuild the projection for a single assignment from its event stream
  and overwrite the cache.
  """
  @spec repair(String.t()) :: {:ok, Assignment.t()} | {:error, :no_events}
  def repair(assignment_id) do
    event_store = resolve_event_store()
    projection_store = resolve_projection_store()

    events = event_store.events_for(assignment_id)

    if events == [] do
      {:error, :no_events}
    else
      projection = Reducer.reduce(events)
      :ok = projection_store.put(assignment_id, projection)
      {:ok, projection}
    end
  end

  @doc """
  Rebuild every projection from persisted events and overwrite the cache.

  Idempotent — safe to call repeatedly.
  """
  @spec rebuild_all() :: :ok
  def rebuild_all do
    event_store = resolve_event_store()
    projection_store = resolve_projection_store()

    event_store.list_events()
    |> Enum.group_by(& &1.assignment_id)
    |> Enum.each(fn {assignment_id, events} ->
      projection = Reducer.reduce(events)
      :ok = projection_store.put(assignment_id, projection)
    end)

    :ok
  end

  @doc """
  Alias for `rebuild_all/0`.
  """
  @spec repair_all() :: :ok
  def repair_all, do: rebuild_all()

  ## Internal

  defp resolve_event_store do
    Application.get_env(
      :dev_ide,
      :assignment_event_store_adapter,
      EventStore.MemoryAdapter
    )
  end

  defp resolve_projection_store do
    Application.get_env(
      :dev_ide,
      :assignment_projection_store_adapter,
      ProjectionStore.MemoryAdapter
    )
  end
end
