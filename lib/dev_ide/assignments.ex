defmodule DevIDE.Assignments do
  @moduledoc """
  Durable assignment orchestration primitives.

  Internally event-sourced:

    1. Command validates the transition against the current projection.
    2. An `%AssignmentEvent{}` is appended to `EventStore`.
    3. Events are replayed through the pure `Reducer`.
    4. The resulting projection is cached in `ProjectionStore`.
    5. The caller receives the derived `%Assignment{}`.

  This module sits on top of `DevIDE.Runs.Ledger` and provides:

    * Assignment lifecycle management (create, claim, start, complete, fail, abandon, expire)
    * Lease semantics with explicit expiry
    * Reconciliation pass hooks
    * Portfolio reducer functions for status views

  It is intentionally read-first and does not perform autonomous retries
  or planning.
  """

  alias DevIDE.Assignments.Assignment
  alias DevIDE.Assignments.Event
  alias DevIDE.Assignments.Reducer
  alias DevIDE.Assignments.StateMachine
  alias DevIDE.Runs.Ledger
  alias DevIDE.Runs.Status

  @default_lease_ms 15 * 60 * 1000

  @spec create(map()) :: {:ok, Assignment.t()} | {:error, term()}
  def create(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    id = Map.get(attrs, :id) || Ecto.UUID.generate()
    run_id = Map.get(attrs, :run_id)
    workspace_id = Map.fetch!(attrs, :workspace_id)

    event = %Event{
      id: Ecto.UUID.generate(),
      assignment_id: id,
      type: :created,
      actor: Map.get(attrs, :actor_id),
      occurred_at: now,
      payload: %{
        workspace_id: workspace_id,
        run_id: run_id,
        metadata: Map.get(attrs, :metadata, %{})
      }
    }

    with {:ok, _event} <- event_store().append(event),
         {:ok, projection} <- rebuild_and_cache(id) do
      if is_binary(run_id) do
        Ledger.run_queued(
          DevIDE.Policy.Decision.allow(:run_command, :manual, %{}),
          %DevIDE.Runners.Assignment{
            id: projection.id,
            workspace_id: projection.workspace_id,
            safe_action_id: "command:unknown",
            safe_action_version: 1,
            status: "queued",
            requested_by: "orchestrator",
            queued_at: now,
            metadata: %{
              run_id: run_id,
              orchestration: true
            }
          },
          %{
            actor_id: Map.get(attrs, :actor_id),
            metadata: Map.get(attrs, :metadata, %{})
          }
        )
      end

      {:ok, projection}
    end
  end

  @spec claim(String.t(), String.t(), keyword()) :: {:ok, Assignment.t()} | {:error, term()}
  def claim(assignment_id, lease_owner, opts \\ []) do
    with {:ok, projection} <- projection_store().get(assignment_id),
         {:ok, "claimed"} <- StateMachine.transition(projection.state, :claim) do
      now = DateTime.utc_now()
      lease_ms = Keyword.get(opts, :lease_ms, default_lease_ms())
      expires_at = DateTime.add(now, lease_ms, :millisecond)

      event = %Event{
        id: Ecto.UUID.generate(),
        assignment_id: assignment_id,
        type: :claimed,
        actor: lease_owner,
        occurred_at: now,
        payload: %{
          lease_owner: lease_owner,
          lease_expires_at: expires_at
        }
      }

      with {:ok, _event} <- event_store().append(event),
           {:ok, updated} <- rebuild_and_cache(assignment_id) do
        Ledger.assignment_claimed(
          %DevIDE.Runners.Assignment{
            id: updated.id,
            workspace_id: updated.workspace_id,
            safe_action_id: "command:unknown",
            safe_action_version: 1,
            status: "claimed",
            claimed_by: lease_owner,
            claimed_at: now,
            lease_expires_at: expires_at,
            queued_at: now,
            metadata: updated.metadata
          },
          lease_owner
        )

        {:ok, updated}
      end
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start(String.t()) :: {:ok, Assignment.t()} | {:error, term()}
  def start(assignment_id) do
    emit(assignment_id, :started, %{})
  end

  @spec complete(String.t()) :: {:ok, Assignment.t()} | {:error, term()}
  def complete(assignment_id) do
    now = DateTime.utc_now()
    emit(assignment_id, :completed, %{completed_at: now})
  end

  @spec fail(String.t(), map()) :: {:ok, Assignment.t()} | {:error, term()}
  def fail(assignment_id, attrs \\ %{}) do
    now = DateTime.utc_now()

    emit(assignment_id, :failed, %{
      failure_reason: Map.get(attrs, :reason),
      completed_at: now
    })
  end

  @spec abandon(String.t(), map()) :: {:ok, Assignment.t()} | {:error, term()}
  def abandon(assignment_id, attrs \\ %{}) do
    now = DateTime.utc_now()

    emit(assignment_id, :abandoned, %{
      failure_reason: Map.get(attrs, :reason),
      completed_at: now
    })
  end

  @spec expire(String.t()) :: {:ok, Assignment.t()} | {:error, term()}
  def expire(assignment_id) do
    now = DateTime.utc_now()

    emit(assignment_id, :expired, %{
      failure_reason: "lease_expired",
      completed_at: now
    })
  end

  @spec get(String.t()) :: {:ok, Assignment.t()} | :error
  def get(assignment_id), do: projection_store().get(assignment_id)

  @spec replay(String.t()) :: [Event.t()]
  def replay(assignment_id), do: event_store().events_for(assignment_id)

  @spec list(keyword()) :: [Assignment.t()]
  def list(opts \\ []), do: projection_store().list(opts)

  @spec list_by_workspace(String.t()) :: [Assignment.t()]
  def list_by_workspace(workspace_id) do
    list(workspace_id: workspace_id)
  end

  @spec rebuild(String.t()) :: {:ok, Assignment.t()} | :error
  def rebuild(assignment_id) do
    events = event_store().events_for(assignment_id)

    if events == [] do
      :error
    else
      projection = Reducer.reduce(events)
      :ok = projection_store().put(assignment_id, projection)
      {:ok, projection}
    end
  end

  @spec reconcile(DateTime.t()) :: [Assignment.t()]
  def reconcile(now \\ DateTime.utc_now()) do
    list()
    |> Enum.reject(fn a -> StateMachine.terminal?(a.state) end)
    |> Enum.filter(fn a -> lease_expired?(a, now) end)
    |> Enum.map(fn a ->
      case expire(a.id) do
        {:ok, expired} -> expired
        _ -> a
      end
    end)
  end

  @spec clear() :: :ok
  def clear do
    :ok = event_store().clear()
    :ok = projection_store().clear()
    :ok
  end

  ## Portfolio reducers

  @spec portfolio([Assignment.t()]) :: map()
  def portfolio(assignments) when is_list(assignments) do
    grouped = Enum.group_by(assignments, & &1.state)

    %{
      total: length(assignments),
      requested: length(Map.get(grouped, "requested", [])),
      queued: length(Map.get(grouped, "queued", [])),
      claimed: length(Map.get(grouped, "claimed", [])),
      running: length(Map.get(grouped, "running", [])),
      completed: length(Map.get(grouped, "completed", [])),
      failed: length(Map.get(grouped, "failed", [])),
      abandoned: length(Map.get(grouped, "abandoned", [])),
      expired: length(Map.get(grouped, "expired", [])),
      terminal: Enum.count(assignments, &StateMachine.terminal?(&1.state)),
      in_progress: Enum.count(assignments, &Status.in_progress?(&1.state))
    }
  end

  @spec workspace_portfolio(String.t()) :: map()
  def workspace_portfolio(workspace_id) do
    workspace_id |> list_by_workspace() |> portfolio()
  end

  ## Internal

  defp emit(assignment_id, event_type, payload) do
    with {:ok, projection} <- projection_store().get(assignment_id),
         {:ok, _next_state} <- StateMachine.transition(projection.state, event_type) do
      event = %Event{
        id: Ecto.UUID.generate(),
        assignment_id: assignment_id,
        type: event_type,
        occurred_at: DateTime.utc_now(),
        payload: payload
      }

      with {:ok, _event} <- event_store().append(event) do
        rebuild_and_cache(assignment_id)
      end
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rebuild_and_cache(assignment_id) do
    events = event_store().events_for(assignment_id)

    if events == [] do
      :error
    else
      projection = Reducer.reduce(events)
      :ok = projection_store().put(assignment_id, projection)
      {:ok, projection}
    end
  end

  defp lease_expired?(%Assignment{lease_expires_at: nil}, _now), do: false

  defp lease_expired?(%Assignment{state: state}, _now)
       when state in ["completed", "failed", "abandoned", "expired"],
       do: false

  defp lease_expired?(%Assignment{lease_expires_at: expires_at}, now) do
    DateTime.compare(expires_at, now) != :gt
  end

  defp default_lease_ms,
    do: Application.get_env(:dev_ide, :assignment_lease_ms, @default_lease_ms)

  defp event_store,
    do:
      Application.get_env(
        :dev_ide,
        :assignment_event_store_adapter,
        DevIDE.Assignments.EventStore.MemoryAdapter
      )

  defp projection_store,
    do:
      Application.get_env(
        :dev_ide,
        :assignment_projection_store_adapter,
        DevIDE.Assignments.ProjectionStore.MemoryAdapter
      )
end
