defmodule DevIDE.Assignments.RecoveryTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Assignments.EventStore.MemoryAdapter, as: EventStore
  alias DevIDE.Assignments.ProjectionStore.MemoryAdapter, as: ProjectionStore
  alias DevIDE.Assignments.Recovery
  alias DevIDE.Assignments.RecoveryAction
  alias DevIDE.Audit

  setup do
    EventStore.clear()
    ProjectionStore.clear()
    Audit.clear()

    Application.put_env(:dev_ide, :assignment_event_store_adapter, EventStore)
    Application.put_env(:dev_ide, :assignment_projection_store_adapter, ProjectionStore)

    on_exit(fn ->
      Application.delete_env(:dev_ide, :assignment_event_store_adapter)
      Application.delete_env(:dev_ide, :assignment_projection_store_adapter)
    end)

    :ok
  end

  describe "propose/1 — missing projection" do
    test "proposes rebuild when events exist but projection is missing" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      ProjectionStore.clear()

      proposals = Recovery.propose(a.id)

      assert length(proposals) == 1
      [proposal] = proposals
      assert proposal.kind == :rebuild_projection
      assert proposal.risk_level == :safe
      assert proposal.assignment_id == a.id
    end

    test "returns empty list when no events exist" do
      proposals = Recovery.propose("nonexistent")
      assert proposals == []
    end
  end

  describe "propose/1 — inconsistent projection" do
    test "proposes repair when cached projection diverges from events" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")

      # Corrupt the projection cache
      {:ok, cached} = ProjectionStore.get(a.id)
      corrupted = %{cached | state: "running"}
      :ok = ProjectionStore.put(a.id, corrupted)

      proposals = Recovery.propose(a.id)

      assert length(proposals) == 1
      [proposal] = proposals
      assert proposal.kind == :repair_projection
      assert proposal.risk_level == :safe
    end
  end

  describe "propose/1 — expired lease" do
    test "proposes expire when lease has passed" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})

      # Claim with a very short lease that's already expired
      past = DateTime.utc_now() |> DateTime.add(-60, :second)

      expired_event = %Assignments.Event{
        id: Ecto.UUID.generate(),
        assignment_id: a.id,
        type: :claimed,
        actor: "runner-1",
        occurred_at: DateTime.utc_now(),
        payload: %{
          lease_owner: "runner-1",
          lease_expires_at: past
        }
      }

      {:ok, _} = EventStore.append(expired_event)
      {:ok, _} = Assignments.rebuild(a.id)

      proposals = Recovery.propose(a.id)

      expire_proposals = Enum.filter(proposals, &(&1.kind == :expire_lease))
      assert length(expire_proposals) == 1

      [proposal] = expire_proposals
      assert proposal.risk_level == :moderate
      assert String.contains?(proposal.reason, "expired")
    end

    test "does not propose expire when lease is still valid" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1", lease_ms: 3600_000)

      proposals = Recovery.propose(a.id)
      expire_proposals = Enum.filter(proposals, &(&1.kind == :expire_lease))
      assert expire_proposals == []
    end

    test "does not propose expire for terminal states" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.complete(a.id)

      proposals = Recovery.propose(a.id)
      expire_proposals = Enum.filter(proposals, &(&1.kind == :expire_lease))
      assert expire_proposals == []
    end
  end

  describe "propose/1 — retryable failed" do
    test "proposes retry for failed assignments" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1", run_id: "run-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.fail(a.id, %{reason: "timeout"})

      proposals = Recovery.propose(a.id)

      retry_proposals = Enum.filter(proposals, &(&1.kind == :retry_assignment))
      assert length(retry_proposals) == 1

      [proposal] = retry_proposals
      assert proposal.risk_level == :high
    end

    test "does not propose retry for non-failed states" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.complete(a.id)

      proposals = Recovery.propose(a.id)
      retry_proposals = Enum.filter(proposals, &(&1.kind == :retry_assignment))
      assert retry_proposals == []
    end
  end

  describe "propose/1 — requeue expired" do
    test "proposes requeue for expired assignments" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1", run_id: "run-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.expire(a.id)

      proposals = Recovery.propose(a.id)

      requeue_proposals = Enum.filter(proposals, &(&1.kind == :requeue_assignment))
      assert length(requeue_proposals) == 1

      [proposal] = requeue_proposals
      assert proposal.risk_level == :high
    end

    test "does not propose requeue for non-expired states" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.fail(a.id, %{reason: "error"})

      proposals = Recovery.propose(a.id)
      requeue_proposals = Enum.filter(proposals, &(&1.kind == :requeue_assignment))
      assert requeue_proposals == []
    end
  end

  describe "propose/1 — clone assignment" do
    test "proposes clone for abandoned assignments" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.abandon(a.id, %{reason: "orphaned"})

      proposals = Recovery.propose(a.id)

      clone_proposals = Enum.filter(proposals, &(&1.kind == :clone_assignment))
      assert length(clone_proposals) == 1

      [proposal] = clone_proposals
      assert proposal.risk_level == :high
    end

    test "does not propose clone for non-abandoned states" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.fail(a.id, %{reason: "error"})

      proposals = Recovery.propose(a.id)
      clone_proposals = Enum.filter(proposals, &(&1.kind == :clone_assignment))
      assert clone_proposals == []
    end
  end

  describe "propose_all/0" do
    test "returns proposals only for assignments with issues" do
      {:ok, _healthy} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, failed} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(failed.id, "runner-1")
      {:ok, _} = Assignments.fail(failed.id, %{reason: "err"})

      proposals = Recovery.propose_all()

      # Should only propose for the failed one, not the healthy requested one
      assert length(proposals) == 1
      [proposal] = proposals
      assert proposal.assignment_id == failed.id
    end

    test "returns empty list when all assignments are healthy" do
      {:ok, _} = Assignments.create(%{workspace_id: "ws-1"})

      proposals = Recovery.propose_all()
      assert proposals == []
    end
  end

  describe "dry_run/1" do
    test "simulates rebuild without mutating" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")

      ProjectionStore.clear()

      [proposal] = Recovery.propose(a.id)
      assert proposal.dry_run_result == nil

      {:ok, dry_run} = Recovery.dry_run(proposal)

      assert dry_run.dry_run_result != nil
      assert dry_run.dry_run_result.action == :rebuild_projection
      assert dry_run.dry_run_result.new_state == "claimed"
      assert dry_run.dry_run_result.event_count == 2

      # Cache still empty (no mutation)
      assert ProjectionStore.get(a.id) == :error
    end

    test "simulates expire lease showing state transition" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")

      # Manually expire to get it into a known state
      {:ok, _} = Assignments.expire(a.id)

      # But we can't propose expire for expired state...
      # Instead let's create a claimed assignment with expired lease
      {:ok, b} = Assignments.create(%{workspace_id: "ws-2"})

      past = DateTime.utc_now() |> DateTime.add(-60, :second)

      expired_event = %Assignments.Event{
        id: Ecto.UUID.generate(),
        assignment_id: b.id,
        type: :claimed,
        actor: "runner-1",
        occurred_at: DateTime.utc_now(),
        payload: %{
          lease_owner: "runner-1",
          lease_expires_at: past
        }
      }

      {:ok, _} = EventStore.append(expired_event)
      {:ok, _} = Assignments.rebuild(b.id)

      [proposal] =
        Recovery.propose(b.id)
        |> Enum.filter(&(&1.kind == :expire_lease))

      {:ok, dry_run} = Recovery.dry_run(proposal)

      assert dry_run.dry_run_result.action == :expire_lease
      assert dry_run.dry_run_result.from_state == "claimed"
      assert dry_run.dry_run_result.to_state == "expired"
    end

    test "simulates retry showing new assignment attributes" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1", run_id: "run-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.fail(a.id, %{reason: "timeout"})

      [proposal] =
        Recovery.propose(a.id)
        |> Enum.filter(&(&1.kind == :retry_assignment))

      {:ok, dry_run} = Recovery.dry_run(proposal)

      assert dry_run.dry_run_result.action == :retry_assignment
      assert dry_run.dry_run_result.original_assignment_id == a.id
      assert is_binary(dry_run.dry_run_result.new_assignment_id)
      assert dry_run.dry_run_result.workspace_id == "ws-1"
      assert dry_run.dry_run_result.run_id == "run-1"
      assert dry_run.dry_run_result.reason == "timeout"

      # No new assignment created
      assert length(Assignments.list()) == 1
    end

    test "simulates clone showing new assignment attributes" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.abandon(a.id, %{reason: "orphaned"})

      [proposal] =
        Recovery.propose(a.id)
        |> Enum.filter(&(&1.kind == :clone_assignment))

      {:ok, dry_run} = Recovery.dry_run(proposal)

      assert dry_run.dry_run_result.action == :clone_assignment
      assert dry_run.dry_run_result.original_assignment_id == a.id
      assert is_binary(dry_run.dry_run_result.new_assignment_id)
      assert dry_run.dry_run_result.workspace_id == "ws-1"

      # No new assignment created
      assert length(Assignments.list()) == 1
    end

    test "simulates requeue showing new assignment attributes" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1", run_id: "run-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.expire(a.id)

      [proposal] =
        Recovery.propose(a.id)
        |> Enum.filter(&(&1.kind == :requeue_assignment))

      {:ok, dry_run} = Recovery.dry_run(proposal)

      assert dry_run.dry_run_result.action == :requeue_assignment
      assert dry_run.dry_run_result.original_assignment_id == a.id
      assert is_binary(dry_run.dry_run_result.new_assignment_id)
      assert dry_run.dry_run_result.workspace_id == "ws-1"
      assert dry_run.dry_run_result.run_id == "run-1"

      # No new assignment created
      assert length(Assignments.list()) == 1
    end
  end

  describe "apply/2 — rebuild_projection" do
    test "rebuilds missing projection through Replay" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      ProjectionStore.clear()

      [proposal] = Recovery.propose(a.id)
      {:ok, _} = Recovery.dry_run(proposal)
      {:ok, applied} = Recovery.apply(proposal, "operator-1")

      assert applied.applied == true
      assert applied.applied_at != nil

      {:ok, projection} = ProjectionStore.get(a.id)
      assert projection.state == "requested"
    end

    test "emits audit entry when applied" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      ProjectionStore.clear()

      [proposal] = Recovery.propose(a.id)
      {:ok, applied} = Recovery.apply(proposal, "operator-1")

      assert applied.applied == true

      events = Audit.list(limit: 10)
      audit = Enum.find(events, &(&1.action == "assignment.recovery.rebuild_projection"))
      assert audit != nil
      assert audit.actor_id == "operator-1"
      assert audit.target_ref == a.id
      assert audit.decision == :allow
    end
  end

  describe "apply/2 — expire_lease" do
    test "expires the assignment through standard command" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})

      past = DateTime.utc_now() |> DateTime.add(-60, :second)

      expired_event = %Assignments.Event{
        id: Ecto.UUID.generate(),
        assignment_id: a.id,
        type: :claimed,
        actor: "runner-1",
        occurred_at: DateTime.utc_now(),
        payload: %{
          lease_owner: "runner-1",
          lease_expires_at: past
        }
      }

      {:ok, _} = EventStore.append(expired_event)
      {:ok, _} = Assignments.rebuild(a.id)

      [proposal] =
        Recovery.propose(a.id)
        |> Enum.filter(&(&1.kind == :expire_lease))

      {:ok, applied} = Recovery.apply(proposal, "operator-1")

      assert applied.applied == true

      {:ok, projection} = ProjectionStore.get(a.id)
      assert projection.state == "expired"
    end
  end

  describe "apply/2 — retry_assignment" do
    test "creates new assignment with same workspace and run_id" do
      {:ok, original} = Assignments.create(%{workspace_id: "ws-1", run_id: "run-1"})
      {:ok, _} = Assignments.claim(original.id, "runner-1")
      {:ok, _} = Assignments.fail(original.id, %{reason: "timeout"})

      [proposal] =
        Recovery.propose(original.id)
        |> Enum.filter(&(&1.kind == :retry_assignment))

      {:ok, applied} = Recovery.apply(proposal, "operator-1")

      assert applied.applied == true

      # Original is untouched
      {:ok, orig} = ProjectionStore.get(original.id)
      assert orig.state == "failed"

      # New assignment exists
      new_id = applied.dry_run_result.new_assignment_id
      {:ok, new_a} = ProjectionStore.get(new_id)
      assert new_a.state == "requested"
      assert new_a.workspace_id == "ws-1"
      assert new_a.run_id == "run-1"

      # Metadata links back
      assert new_a.metadata.retried_from == original.id
    end
  end

  describe "apply/2 — requeue_assignment" do
    test "creates new assignment with same workspace and run_id" do
      {:ok, original} = Assignments.create(%{workspace_id: "ws-1", run_id: "run-1"})
      {:ok, _} = Assignments.claim(original.id, "runner-1")
      {:ok, _} = Assignments.expire(original.id)

      [proposal] =
        Recovery.propose(original.id)
        |> Enum.filter(&(&1.kind == :requeue_assignment))

      {:ok, applied} = Recovery.apply(proposal, "operator-1")

      assert applied.applied == true

      # Original untouched
      {:ok, orig} = ProjectionStore.get(original.id)
      assert orig.state == "expired"

      # New assignment created
      new_id = applied.dry_run_result.new_assignment_id
      {:ok, new_a} = ProjectionStore.get(new_id)
      assert new_a.state == "requested"
      assert new_a.workspace_id == "ws-1"
      assert new_a.run_id == "run-1"
      assert new_a.metadata.requeued_from == original.id
    end
  end

  describe "apply/2 — clone_assignment" do
    test "creates new assignment with same workspace" do
      {:ok, original} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(original.id, "runner-1")
      {:ok, _} = Assignments.abandon(original.id, %{reason: "orphaned"})

      [proposal] =
        Recovery.propose(original.id)
        |> Enum.filter(&(&1.kind == :clone_assignment))

      {:ok, applied} = Recovery.apply(proposal, "operator-1")

      assert applied.applied == true

      # Original untouched
      {:ok, orig} = ProjectionStore.get(original.id)
      assert orig.state == "abandoned"

      # New assignment created
      new_id = applied.dry_run_result.new_assignment_id
      {:ok, new_a} = ProjectionStore.get(new_id)
      assert new_a.state == "requested"
      assert new_a.workspace_id == "ws-1"
      assert new_a.metadata.cloned_from == original.id
    end
  end

  describe "apply/2 — stale proposals" do
    test "rejects stale expire proposal" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})

      past = DateTime.utc_now() |> DateTime.add(-60, :second)

      expired_event = %Assignments.Event{
        id: Ecto.UUID.generate(),
        assignment_id: a.id,
        type: :claimed,
        actor: "runner-1",
        occurred_at: DateTime.utc_now(),
        payload: %{
          lease_owner: "runner-1",
          lease_expires_at: past
        }
      }

      {:ok, _} = EventStore.append(expired_event)
      {:ok, _} = Assignments.rebuild(a.id)

      [proposal] =
        Recovery.propose(a.id)
        |> Enum.filter(&(&1.kind == :expire_lease))

      # Apply manually outside of recovery to change state
      {:ok, _} = Assignments.expire(a.id)

      # Now the proposal is stale
      assert {:error, :stale} = Recovery.apply(proposal, "operator-1")
    end

    test "rejects stale retry proposal" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.fail(a.id, %{reason: "err"})

      [proposal] =
        Recovery.propose(a.id)
        |> Enum.filter(&(&1.kind == :retry_assignment))

      # State changes from failed to something else (can't really happen via
      # SM, but we can corrupt projection directly)
      {:ok, cached} = ProjectionStore.get(a.id)
      :ok = ProjectionStore.put(a.id, %{cached | state: "completed"})

      assert {:error, :stale} = Recovery.apply(proposal, "operator-1")
    end

    test "rejects stale requeue proposal" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.expire(a.id)

      [proposal] =
        Recovery.propose(a.id)
        |> Enum.filter(&(&1.kind == :requeue_assignment))

      {:ok, cached} = ProjectionStore.get(a.id)
      :ok = ProjectionStore.put(a.id, %{cached | state: "completed"})

      assert {:error, :stale} = Recovery.apply(proposal, "operator-1")
    end

    test "rejects stale clone proposal" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.abandon(a.id, %{reason: "orphaned"})

      [proposal] =
        Recovery.propose(a.id)
        |> Enum.filter(&(&1.kind == :clone_assignment))

      {:ok, cached} = ProjectionStore.get(a.id)
      :ok = ProjectionStore.put(a.id, %{cached | state: "completed"})

      assert {:error, :stale} = Recovery.apply(proposal, "operator-1")
    end
  end

  describe "RecoveryAction struct" do
    test "enforces required fields" do
      action =
        RecoveryAction.new(
          id: Ecto.UUID.generate(),
          assignment_id: "a-1",
          kind: :rebuild_projection,
          reason: "test",
          risk_level: :safe,
          proposed_at: DateTime.utc_now()
        )

      assert action.id != nil
      assert action.assignment_id == "a-1"
      assert action.kind == :rebuild_projection
      assert action.applied == false
      assert action.dry_run_result == nil
    end
  end
end
