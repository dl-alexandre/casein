defmodule DevIDE.Assignments.Recovery do
  @moduledoc """
  Read-first recovery actions for assignments.

  ## Workflow

    1. **Propose** — `propose/1` analyses an assignment and suggests recovery
       actions based on its current state.  No mutation occurs.

    2. **Dry-run** — `dry_run/1` simulates executing an action and returns
       what would happen without writing anything.

    3. **Apply** — `apply/2` executes the action through the standard
       assignment event store and emits an audit entry.  Requires an
       explicit operator identity.

  ## Risk levels

    * `:safe` — projection cache only (replay/rebuild)
    * `:moderate` — standard event transitions (expire)
    * `:high` — creates new causality (retry, clone)

  ## Rules

    * Proposals are never automatically applied.
    * Every applied action is audited.
    * Stale proposals (state changed since proposal) are rejected.
    * Retry/requeue/clone creates a **new** assignment — the original is untouched.
  """

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Assignment
  alias DevIDE.Assignments.RecoveryAction
  alias DevIDE.Assignments.Replay
  alias DevIDE.Assignments.StateMachine
  alias DevIDE.Assignments.Status
  alias DevIDE.Audit

  @type proposal :: RecoveryAction.t()

  ## Proposals

  @doc """
  Generate recovery proposals for a single assignment.

  Returns an empty list when no recovery is needed.
  """
  @spec propose(String.t(), keyword()) :: [proposal()]
  def propose(assignment_id, opts \\ []) do
    actor = Keyword.get(opts, :proposed_by)

    case resolve_projection_store().get(assignment_id) do
      :error ->
        propose_for_missing(assignment_id, actor)

      {:ok, projection} ->
        proposals = []
        proposals = maybe_add_inconsistent(proposals, assignment_id, projection, actor)
        proposals = maybe_add_expired(proposals, projection, actor)
        proposals = maybe_add_retry(proposals, projection, actor)
        proposals = maybe_add_requeue(proposals, projection, actor)
        proposals = maybe_add_clone(proposals, projection, actor)
        proposals
    end
  end

  @doc """
  Generate recovery proposals for ALL assignments that have issues.

  Skips assignments that are healthy (projection consistent, no expired
  lease, not retryable).
  """
  @spec propose_all(keyword()) :: [proposal()]
  def propose_all(opts \\ []) do
    event_store = resolve_event_store()

    all_events = event_store.list_events()

    if all_events == [] do
      []
    else
      events_by_assignment = Enum.group_by(all_events, & &1.assignment_id)

      Enum.flat_map(events_by_assignment, fn {id, _events} ->
        propose(id, opts)
      end)
    end
  end

  ## Dry-run

  @doc """
  Simulate executing a recovery action without mutating state.

  Returns the action with `dry_run_result` populated.
  """
  @spec dry_run(proposal()) :: {:ok, proposal()} | {:error, :stale | term()}
  def dry_run(%RecoveryAction{} = action) do
    with :ok <- check_freshness(action) do
      result = simulate(action)
      {:ok, %{action | dry_run_result: result}}
    end
  end

  ## Apply

  @doc """
  Execute a recovery action, mutating state through the canonical
  assignment commands and emitting an audit entry.

  Returns the updated action with `applied: true` and `applied_at` set.
  """
  @spec apply(proposal(), String.t()) :: {:ok, proposal()} | {:error, :stale | term()}
  def apply(%RecoveryAction{} = action, operator_id) when is_binary(operator_id) do
    with :ok <- check_freshness(action) do
      case execute(action, operator_id) do
        {:ok, result} ->
          audit_action(action, operator_id, result)

          updated = %{
            action
            | applied: true,
              applied_at: DateTime.utc_now(),
              dry_run_result: result
          }

          {:ok, updated}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  ## Internal — proposal generation

  defp propose_for_missing(assignment_id, actor) do
    events = resolve_event_store().events_for(assignment_id)

    if events == [] do
      []
    else
      [
        RecoveryAction.new(
          id: Ecto.UUID.generate(),
          assignment_id: assignment_id,
          kind: :rebuild_projection,
          reason: "Projection missing from cache — events exist but no cached projection",
          risk_level: :safe,
          proposed_by: actor,
          proposed_at: DateTime.utc_now()
        )
      ]
    end
  end

  defp maybe_add_inconsistent(proposals, assignment_id, _projection, actor) do
    case Replay.verify(assignment_id) do
      {:ok, %{status: :inconsistent}} ->
        [
          RecoveryAction.new(
            id: Ecto.UUID.generate(),
            assignment_id: assignment_id,
            kind: :repair_projection,
            reason: "Cached projection does not match event stream replay",
            risk_level: :safe,
            proposed_by: actor,
            proposed_at: DateTime.utc_now()
          )
          | proposals
        ]

      _ ->
        proposals
    end
  end

  defp maybe_add_expired(proposals, %Assignment{state: state} = a, actor)
       when state in ["claimed", "running"] do
    now = DateTime.utc_now()

    if a.lease_expires_at != nil and DateTime.compare(a.lease_expires_at, now) != :gt do
      [
        RecoveryAction.new(
          id: Ecto.UUID.generate(),
          assignment_id: a.id,
          kind: :expire_lease,
          reason: "Lease expired at #{format_dt(a.lease_expires_at)}",
          risk_level: :moderate,
          proposed_by: actor,
          proposed_at: DateTime.utc_now()
        )
        | proposals
      ]
    else
      proposals
    end
  end

  defp maybe_add_expired(proposals, _projection, _actor), do: proposals

  defp maybe_add_retry(proposals, %Assignment{} = a, actor) do
    if Status.retryable?(a.state) do
      add_retry(proposals, a, actor)
    else
      proposals
    end
  end

  defp maybe_add_retry(proposals, _projection, _actor), do: proposals

  defp add_retry(proposals, %Assignment{} = a, actor) do
    [
      RecoveryAction.new(
        id: Ecto.UUID.generate(),
        assignment_id: a.id,
        kind: :retry_assignment,
        reason: "Assignment failed — create new assignment with same run context",
        risk_level: :high,
        proposed_by: actor,
        proposed_at: DateTime.utc_now()
      )
      | proposals
    ]
  end

  defp maybe_add_requeue(proposals, %Assignment{} = a, actor) do
    if Status.requeueable?(a.state) do
      add_requeue(proposals, a, actor)
    else
      proposals
    end
  end

  defp maybe_add_requeue(proposals, _projection, _actor), do: proposals

  defp add_requeue(proposals, %Assignment{} = a, actor) do
    [
      RecoveryAction.new(
        id: Ecto.UUID.generate(),
        assignment_id: a.id,
        kind: :requeue_assignment,
        reason: "Assignment expired — create new assignment with same run context",
        risk_level: :high,
        proposed_by: actor,
        proposed_at: DateTime.utc_now()
      )
      | proposals
    ]
  end

  defp maybe_add_clone(proposals, %Assignment{} = a, actor) do
    if Status.cloneable?(a.state) do
      add_clone(proposals, a, actor)
    else
      proposals
    end
  end

  defp maybe_add_clone(proposals, _projection, _actor), do: proposals

  defp add_clone(proposals, %Assignment{} = a, actor) do
    [
      RecoveryAction.new(
        id: Ecto.UUID.generate(),
        assignment_id: a.id,
        kind: :clone_assignment,
        reason: "Assignment abandoned — clone into new assignment",
        risk_level: :high,
        proposed_by: actor,
        proposed_at: DateTime.utc_now()
      )
      | proposals
    ]
  end

  ## Internal — simulation

  defp simulate(%RecoveryAction{kind: :rebuild_projection, assignment_id: id}) do
    events = resolve_event_store().events_for(id)
    projection = DevIDE.Assignments.Reducer.reduce(events)

    %{
      action: :rebuild_projection,
      assignment_id: id,
      new_state: projection.state,
      event_count: length(events)
    }
  end

  defp simulate(%RecoveryAction{kind: :repair_projection, assignment_id: id}) do
    events = resolve_event_store().events_for(id)
    projection = DevIDE.Assignments.Reducer.reduce(events)

    %{
      action: :repair_projection,
      assignment_id: id,
      new_state: projection.state,
      event_count: length(events)
    }
  end

  defp simulate(%RecoveryAction{kind: :expire_lease, assignment_id: id}) do
    with {:ok, projection} <- resolve_projection_store().get(id),
         {:ok, next_state} <- StateMachine.transition(projection.state, :expired) do
      %{
        action: :expire_lease,
        assignment_id: id,
        from_state: projection.state,
        to_state: next_state
      }
    else
      :error -> %{action: :expire_lease, assignment_id: id, error: :projection_not_found}
      {:error, reason} -> %{action: :expire_lease, assignment_id: id, error: reason}
    end
  end

  defp simulate(%RecoveryAction{kind: :retry_assignment, assignment_id: id}) do
    with {:ok, projection} <- resolve_projection_store().get(id) do
      new_id = Ecto.UUID.generate()

      %{
        action: :retry_assignment,
        original_assignment_id: id,
        new_assignment_id: new_id,
        workspace_id: projection.workspace_id,
        run_id: projection.run_id,
        reason: projection.failure_reason
      }
    else
      :error -> %{action: :retry_assignment, assignment_id: id, error: :projection_not_found}
    end
  end

  defp simulate(%RecoveryAction{kind: :requeue_assignment, assignment_id: id}) do
    with {:ok, projection} <- resolve_projection_store().get(id) do
      new_id = Ecto.UUID.generate()

      %{
        action: :requeue_assignment,
        original_assignment_id: id,
        new_assignment_id: new_id,
        workspace_id: projection.workspace_id,
        run_id: projection.run_id,
        reason: projection.failure_reason
      }
    else
      :error -> %{action: :requeue_assignment, assignment_id: id, error: :projection_not_found}
    end
  end

  defp simulate(%RecoveryAction{kind: :clone_assignment, assignment_id: id}) do
    simulate_clone(id, :clone_assignment)
  end

  defp simulate(%RecoveryAction{kind: :clone_requeue, assignment_id: id}) do
    simulate_clone(id, :clone_requeue)
  end

  defp simulate_clone(id, kind) do
    with {:ok, projection} <- resolve_projection_store().get(id) do
      new_id = Ecto.UUID.generate()

      %{
        action: kind,
        original_assignment_id: id,
        new_assignment_id: new_id,
        workspace_id: projection.workspace_id,
        reason: projection.failure_reason
      }
    else
      :error -> %{action: kind, assignment_id: id, error: :projection_not_found}
    end
  end

  ## Internal — execution

  defp execute(%RecoveryAction{kind: kind, assignment_id: id}, operator_id)
       when kind in [:rebuild_projection, :repair_projection] do
    with {:ok, projection} <- Replay.repair(id) do
      {:ok,
       %{
         action: kind,
         assignment_id: id,
         new_state: projection.state,
         operator_id: operator_id
       }}
    end
  end

  defp execute(%RecoveryAction{kind: :expire_lease, assignment_id: id}, operator_id) do
    with {:ok, projection} <- Assignments.expire(id) do
      {:ok,
       %{
         action: :expire_lease,
         assignment_id: id,
         new_state: projection.state,
         operator_id: operator_id
       }}
    end
  end

  defp execute(%RecoveryAction{kind: :retry_assignment, assignment_id: id}, operator_id) do
    with {:ok, original} <- resolve_projection_store().get(id),
         {:ok, new_assignment} <-
           Assignments.create(%{
             workspace_id: original.workspace_id,
             run_id: original.run_id,
             actor_id: operator_id,
             metadata: %{
               retried_from: id,
               failure_reason: original.failure_reason
             }
           }) do
      {:ok,
       %{
         action: :retry_assignment,
         original_assignment_id: id,
         new_assignment_id: new_assignment.id,
         workspace_id: original.workspace_id,
         operator_id: operator_id
       }}
    end
  end

  defp execute(%RecoveryAction{kind: :requeue_assignment, assignment_id: id}, operator_id) do
    with {:ok, original} <- resolve_projection_store().get(id),
         {:ok, new_assignment} <-
           Assignments.create(%{
             workspace_id: original.workspace_id,
             run_id: original.run_id,
             actor_id: operator_id,
             metadata: %{
               requeued_from: id,
               failure_reason: original.failure_reason
             }
           }) do
      {:ok,
       %{
         action: :requeue_assignment,
         original_assignment_id: id,
         new_assignment_id: new_assignment.id,
         workspace_id: original.workspace_id,
         operator_id: operator_id
       }}
    end
  end

  defp execute(%RecoveryAction{kind: kind, assignment_id: id}, operator_id)
       when kind in [:clone_assignment, :clone_requeue] do
    with {:ok, original} <- resolve_projection_store().get(id),
         {:ok, new_assignment} <-
           Assignments.create(%{
             workspace_id: original.workspace_id,
             actor_id: operator_id,
             metadata: %{
               cloned_from: id,
               failure_reason: original.failure_reason
             }
           }) do
      {:ok,
       %{
         action: kind,
         original_assignment_id: id,
         new_assignment_id: new_assignment.id,
         workspace_id: original.workspace_id,
         operator_id: operator_id
       }}
    end
  end

  ## Internal — staleness check

  defp check_freshness(%RecoveryAction{kind: kind, assignment_id: id})
       when kind in [:rebuild_projection, :repair_projection] do
    events = resolve_event_store().events_for(id)
    if events == [], do: {:error, :no_events}, else: :ok
  end

  defp check_freshness(%RecoveryAction{kind: :expire_lease, assignment_id: id}) do
    with {:ok, projection} <- resolve_projection_store().get(id) do
      if projection.state in ["claimed", "running"] do
        :ok
      else
        {:error, :stale}
      end
    else
      :error -> {:error, :stale}
    end
  end

  defp check_freshness(%RecoveryAction{kind: :retry_assignment, assignment_id: id}) do
    with {:ok, projection} <- resolve_projection_store().get(id) do
      if Status.retryable?(projection.state), do: :ok, else: {:error, :stale}
    else
      :error -> {:error, :stale}
    end
  end

  defp check_freshness(%RecoveryAction{kind: :requeue_assignment, assignment_id: id}) do
    with {:ok, projection} <- resolve_projection_store().get(id) do
      if Status.requeueable?(projection.state), do: :ok, else: {:error, :stale}
    else
      :error -> {:error, :stale}
    end
  end

  defp check_freshness(%RecoveryAction{kind: kind, assignment_id: id})
       when kind in [:clone_assignment, :clone_requeue] do
    with {:ok, projection} <- resolve_projection_store().get(id) do
      if Status.cloneable?(projection.state), do: :ok, else: {:error, :stale}
    else
      :error -> {:error, :stale}
    end
  end

  ## Internal — audit

  defp audit_action(action, operator_id, result) do
    Audit.emit!(%{
      action: "assignment.recovery.#{action.kind}",
      actor_id: operator_id,
      target_type: "assignment",
      target_ref: action.assignment_id,
      decision: :allow,
      metadata: %{
        recovery_action_id: action.id,
        result: result
      }
    })
  end

  ## Internal — helpers

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp resolve_event_store do
    Application.get_env(
      :dev_ide,
      :assignment_event_store_adapter,
      DevIDE.Assignments.EventStore.MemoryAdapter
    )
  end

  defp resolve_projection_store do
    Application.get_env(
      :dev_ide,
      :assignment_projection_store_adapter,
      DevIDE.Assignments.ProjectionStore.MemoryAdapter
    )
  end
end
