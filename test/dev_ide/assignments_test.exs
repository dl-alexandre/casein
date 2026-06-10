defmodule DevIDE.AssignmentsTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Assignment
  alias DevIDE.Assignments.Event
  alias DevIDE.Assignments.ProjectionStore.MemoryAdapter, as: ProjectionStore
  alias DevIDE.Assignments.Reducer
  alias DevIDE.Assignments.StateMachine

  setup do
    prev_event_store = Application.get_env(:dev_ide, :assignment_event_store_adapter)
    prev_projection_store = Application.get_env(:dev_ide, :assignment_projection_store_adapter)

    Application.put_env(
      :dev_ide,
      :assignment_event_store_adapter,
      DevIDE.Assignments.EventStore.MemoryAdapter
    )

    Application.put_env(:dev_ide, :assignment_projection_store_adapter, ProjectionStore)
    Assignments.clear()

    on_exit(fn ->
      Assignments.clear()
      restore_env(:assignment_event_store_adapter, prev_event_store)
      restore_env(:assignment_projection_store_adapter, prev_projection_store)
    end)

    :ok
  end

  describe "create/1" do
    test "creates an assignment in requested state" do
      assert {:ok, %Assignment{} = a} =
               Assignments.create(%{workspace_id: "ws-1", run_id: "run-1"})

      assert a.state == "requested"
      assert a.workspace_id == "ws-1"
      assert a.run_id == "run-1"
      assert a.lease_owner == nil
      assert a.lease_expires_at == nil
    end

    test "creates an assignment without run_id" do
      assert {:ok, %Assignment{} = a} = Assignments.create(%{workspace_id: "ws-1"})
      assert a.run_id == nil
      assert a.state == "requested"
    end
  end

  describe "claim/3" do
    test "transitions requested -> claimed with lease" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      assert {:ok, claimed} = Assignments.claim(a.id, "runner-1", lease_ms: 5_000)
      assert claimed.state == "claimed"
      assert claimed.lease_owner == "runner-1"
      assert claimed.claimed_at != nil
      assert claimed.lease_expires_at != nil
    end

    test "refuses to claim a terminal assignment" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, a} = Assignments.claim(a.id, "runner-1")
      {:ok, _a} = Assignments.complete(a.id)
      assert Assignments.reconcile(DateTime.utc_now()) == []
    end

    test "ignores assignments without lease_expires_at" do
      {:ok, _a} = Assignments.create(%{workspace_id: "ws-1"})
      assert Assignments.reconcile(DateTime.utc_now()) == []
    end
  end

  describe "StateMachine" do
    test "all states" do
      assert "requested" in StateMachine.states()
      assert "queued" in StateMachine.states()
      assert "claimed" in StateMachine.states()
      assert "running" in StateMachine.states()
      assert "completed" in StateMachine.states()
      assert "failed" in StateMachine.states()
      assert "abandoned" in StateMachine.states()
      assert "expired" in StateMachine.states()
    end

    test "terminal states" do
      for s <- ["completed", "failed", "abandoned", "expired"] do
        assert StateMachine.terminal?(s)
      end

      for s <- ["requested", "queued", "claimed", "running"] do
        refute StateMachine.terminal?(s)
      end
    end

    test "valid transitions" do
      assert {:ok, "queued"} = StateMachine.transition("requested", :queue)
      assert {:ok, "claimed"} = StateMachine.transition("queued", :claim)
      assert {:ok, "running"} = StateMachine.transition("claimed", :started)
      assert {:ok, "completed"} = StateMachine.transition("running", :completed)
      assert {:ok, "failed"} = StateMachine.transition("running", :failed)
      assert {:ok, "expired"} = StateMachine.transition("running", :expired)
      assert {:ok, "abandoned"} = StateMachine.transition("running", :abandoned)
    end

    test "invalid transitions" do
      assert {:error, :invalid_transition} = StateMachine.transition("requested", :started)
      assert {:error, :invalid_transition} = StateMachine.transition("queued", :started)
      assert {:error, :invalid_transition} = StateMachine.transition("running", :claim)
    end

    test "terminal transitions are rejected" do
      assert {:error, :terminal} = StateMachine.transition("completed", :fail)
      assert {:error, :terminal} = StateMachine.transition("failed", :expire)
    end
  end

  describe "portfolio/1" do
    test "computes counts by state" do
      for _ <- 1..3, do: Assignments.create(%{workspace_id: "ws-1"})

      for _ <- 1..2 do
        {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
        {:ok, _} = Assignments.claim(a.id, "r1")
      end

      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, a} = Assignments.claim(a.id, "r1")
      {:ok, _} = Assignments.start(a.id)

      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, a} = Assignments.claim(a.id, "r1")
      {:ok, _} = Assignments.complete(a.id)

      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, a} = Assignments.claim(a.id, "r1")
      {:ok, _} = Assignments.fail(a.id, %{reason: "err"})

      portfolio = Assignments.list() |> Assignments.portfolio()

      assert portfolio.total == 8
      assert portfolio.requested == 3
      assert portfolio.queued == 0
      assert portfolio.claimed == 2
      assert portfolio.running == 1
      assert portfolio.completed == 1
      assert portfolio.failed == 1
      assert portfolio.terminal == 2
      assert portfolio.in_progress == 6
    end
  end

  describe "workspace_portfolio/1" do
    test "filters by workspace" do
      Assignments.create(%{workspace_id: "ws-a"})
      Assignments.create(%{workspace_id: "ws-b"})

      p = Assignments.workspace_portfolio("ws-a")
      assert p.total == 1
    end
  end

  describe "list/1" do
    test "filters projections by run_id and state" do
      {:ok, claimed} = Assignments.create(%{workspace_id: "ws-1", run_id: "run-a"})
      {:ok, claimed} = Assignments.claim(claimed.id, "runner-1")
      {:ok, _requested} = Assignments.create(%{workspace_id: "ws-1", run_id: "run-b"})

      assert [%{id: claimed_id}] = Assignments.list(run_id: "run-a", state: "claimed")
      assert claimed_id == claimed.id
      assert [] = Assignments.list(run_id: "run-b", state: "claimed")
    end
  end

  describe "rebuild/1" do
    test "restores a projection from the event stream after cache loss" do
      {:ok, assignment} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _claimed} = Assignments.claim(assignment.id, "runner-1")

      ProjectionStore.clear()
      assert :error = Assignments.get(assignment.id)

      assert {:ok, rebuilt} = Assignments.rebuild(assignment.id)
      assert rebuilt.state == "claimed"
      assert rebuilt.lease_owner == "runner-1"

      assert {:ok, cached} = Assignments.get(assignment.id)
      assert cached == rebuilt
    end

    test "returns :error when no event stream exists" do
      assert :error = Assignments.rebuild("missing-assignment")
    end
  end

  describe "event sourcing" do
    test "create emits a :created event with sequence 1" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      [event] = Assignments.replay(a.id)

      assert event.type == :created
      assert event.sequence == 1
      assert event.payload.workspace_id == "ws-1"
    end

    test "events are monotonically sequenced" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.start(a.id)
      {:ok, _} = Assignments.complete(a.id)

      events = Assignments.replay(a.id)
      sequences = Enum.map(events, & &1.sequence)
      assert sequences == Enum.sort(sequences)
      assert length(Enum.uniq(sequences)) == 4
    end

    test "replay rebuilds the same projection" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.start(a.id)
      {:ok, _} = Assignments.complete(a.id)

      events = Assignments.replay(a.id)
      rebuilt = DevIDE.Assignments.Reducer.reduce(events)

      {:ok, projection} = Assignments.get(a.id)
      assert rebuilt.state == projection.state
      assert rebuilt.lease_owner == projection.lease_owner
      assert rebuilt.completed_at == projection.completed_at
    end

    test "reducer ignores unknown event types" do
      import DevIDE.Assignments.Reducer
      import DevIDE.Assignments.Event

      events = [
        %Event{
          id: Ecto.UUID.generate(),
          assignment_id: "a-1",
          sequence: 1,
          type: :created,
          occurred_at: DateTime.utc_now(),
          payload: %{workspace_id: "ws-1"}
        },
        %Event{
          id: Ecto.UUID.generate(),
          assignment_id: "a-1",
          sequence: 2,
          type: :garbage,
          occurred_at: DateTime.utc_now(),
          payload: %{}
        }
      ]

      result = reduce(events)
      assert result.state == "requested"
    end

    test "reducer sorts out-of-order events before projecting and tracing" do
      now = DateTime.utc_now()

      events = [
        assignment_event("a-ordered", 3, :started, DateTime.add(now, 2), %{}),
        assignment_event(
          "a-ordered",
          1,
          :created,
          now,
          %{workspace_id: "ws-1", metadata: %{priority: "high"}}
        ),
        assignment_event(
          "a-ordered",
          2,
          :claimed,
          DateTime.add(now, 1),
          %{lease_owner: "runner-1", lease_expires_at: DateTime.add(now, 60)}
        )
      ]

      assert Reducer.reduce(events).state == "running"

      trace =
        events
        |> Reducer.trace()
        |> Enum.map(fn {event, before_state, projection} ->
          {event.type, before_state, projection.state}
        end)

      assert trace == [
               {:created, nil, "requested"},
               {:claimed, "requested", "claimed"},
               {:started, "claimed", "running"}
             ]
    end
  end

  describe "subscriptions" do
    test "broadcasts notification after create" do
      :ok = Assignments.subscribe()
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})

      assert_receive {DevIDE.Assignments, notification}
      assert notification.assignment_id == a.id
      assert notification.event_type == :created
      assert notification.sequence == 1
      assert notification.projection.state == "requested"
    end

    test "broadcasts notification after claim" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      :ok = Assignments.subscribe(a.id)
      {:ok, _} = Assignments.claim(a.id, "runner-1")

      assert_receive {DevIDE.Assignments, notification}
      assert notification.assignment_id == a.id
      assert notification.event_type == :claimed
      assert notification.projection.state == "claimed"
      assert notification.projection.lease_owner == "runner-1"
    end

    test "scoped subscription ignores other assignments" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, b} = Assignments.create(%{workspace_id: "ws-1"})
      :ok = Assignments.subscribe(a.id)
      {:ok, _} = Assignments.claim(b.id, "runner-1")

      refute_receive {DevIDE.Assignments, _}
    end

    test "global subscription receives all assignments" do
      :ok = Assignments.subscribe()
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, b} = Assignments.create(%{workspace_id: "ws-1"})

      assert_receive {DevIDE.Assignments, n1}
      assert n1.assignment_id == a.id

      assert_receive {DevIDE.Assignments, n2}
      assert n2.assignment_id == b.id
    end

    test "broadcast only after projection commit succeeds" do
      :ok = Assignments.subscribe()
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, _} = Assignments.complete(a.id)

      # Wait for all three notifications
      assert_receive {DevIDE.Assignments, %{event_type: :created}}
      assert_receive {DevIDE.Assignments, %{event_type: :claimed}}
      assert_receive {DevIDE.Assignments, %{event_type: :completed}}

      # Verify final projection matches
      {:ok, projection} = Assignments.get(a.id)
      assert projection.state == "completed"
    end
  end

  defp assignment_event(assignment_id, sequence, type, occurred_at, payload) do
    %Event{
      id: Ecto.UUID.generate(),
      assignment_id: assignment_id,
      sequence: sequence,
      type: type,
      occurred_at: occurred_at,
      payload: payload
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
