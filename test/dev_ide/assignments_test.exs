defmodule DevIDE.AssignmentsTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Assignment
  alias DevIDE.Assignments.Event
  alias DevIDE.Assignments.StateMachine

  setup do
    Assignments.clear()
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
  end
end
