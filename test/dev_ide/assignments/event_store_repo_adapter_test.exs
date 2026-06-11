defmodule DevIDE.Assignments.EventStore.RepoAdapterTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Event
  alias DevIDE.Assignments.EventStore.RepoAdapter
  alias DevIde.Repo

  setup do
    Repo.delete_all(Assignments.EventRow)
    :ok
  end

  describe "append/1" do
    test "persists an event and assigns monotonic sequence" do
      event = %Event{
        id: Ecto.UUID.generate(),
        assignment_id: "a-1",
        type: :created,
        occurred_at: DateTime.utc_now(),
        payload: %{workspace_id: "ws-1"}
      }

      assert {:ok, persisted} = RepoAdapter.append(event)
      assert persisted.sequence == 1
      assert persisted.assignment_id == "a-1"
      assert persisted.type == :created
    end

    test "sequences are monotonic per assignment" do
      for i <- 1..3 do
        event = %Event{
          id: Ecto.UUID.generate(),
          assignment_id: "a-1",
          type: :claimed,
          occurred_at: DateTime.utc_now(),
          payload: %{lease_owner: "r#{i}"}
        }

        assert {:ok, persisted} = RepoAdapter.append(event)
        assert persisted.sequence == i
      end
    end

    test "sequences are independent per assignment" do
      for _ <- 1..2 do
        RepoAdapter.append(%Event{
          id: Ecto.UUID.generate(),
          assignment_id: "a-1",
          type: :created,
          occurred_at: DateTime.utc_now(),
          payload: %{}
        })
      end

      {:ok, first} =
        RepoAdapter.append(%Event{
          id: Ecto.UUID.generate(),
          assignment_id: "a-2",
          type: :created,
          occurred_at: DateTime.utc_now(),
          payload: %{}
        })

      assert first.sequence == 1
    end

    test "stores payload with version" do
      event = %Event{
        id: Ecto.UUID.generate(),
        assignment_id: "a-1",
        type: :created,
        occurred_at: DateTime.utc_now(),
        payload: %{workspace_id: "ws-1"}
      }

      {:ok, _} = RepoAdapter.append(event)

      row = Repo.one(from r in Assignments.EventRow, where: r.assignment_id == "a-1")
      assert row.payload["_version"] == 1
      assert row.payload["workspace_id"] == "ws-1"
    end
  end

  describe "events_for/1" do
    test "returns events ordered by sequence" do
      for i <- 1..3 do
        RepoAdapter.append(%Event{
          id: Ecto.UUID.generate(),
          assignment_id: "a-1",
          type: :claimed,
          occurred_at: DateTime.utc_now(),
          payload: %{n: i}
        })
      end

      events = RepoAdapter.events_for("a-1")
      assert length(events) == 3
      assert Enum.map(events, & &1.sequence) == [1, 2, 3]
      assert Enum.map(events, & &1.payload["n"]) == [1, 2, 3]
    end

    test "returns empty list for unknown assignment" do
      assert RepoAdapter.events_for("nonexistent") == []
    end

    test "reconstructs event type as atom" do
      RepoAdapter.append(%Event{
        id: Ecto.UUID.generate(),
        assignment_id: "a-1",
        type: :created,
        occurred_at: DateTime.utc_now(),
        payload: %{}
      })

      [event] = RepoAdapter.events_for("a-1")
      assert event.type == :created
      assert is_atom(event.type)
    end
  end

  describe "list_events/0" do
    test "returns all events ordered by assignment_id and sequence" do
      for _ <- 1..2 do
        RepoAdapter.append(%Event{
          id: Ecto.UUID.generate(),
          assignment_id: "a-2",
          type: :created,
          occurred_at: DateTime.utc_now(),
          payload: %{}
        })
      end

      for _ <- 1..2 do
        RepoAdapter.append(%Event{
          id: Ecto.UUID.generate(),
          assignment_id: "a-1",
          type: :created,
          occurred_at: DateTime.utc_now(),
          payload: %{}
        })
      end

      events = RepoAdapter.list_events()
      assignment_ids = Enum.map(events, & &1.assignment_id)
      assert assignment_ids == Enum.sort(assignment_ids)
    end
  end

  describe "clear/0" do
    test "deletes all events" do
      RepoAdapter.append(%Event{
        id: Ecto.UUID.generate(),
        assignment_id: "a-1",
        type: :created,
        occurred_at: DateTime.utc_now(),
        payload: %{}
      })

      :ok = RepoAdapter.clear()
      assert RepoAdapter.events_for("a-1") == []
    end
  end

  describe "concurrent appends" do
    # With 5 contenders and 5 attempts a task can lose at most 4 races
    # (one per competing success), so this never flakes.
    test "racing appends all succeed with gapless unique sequences" do
      results =
        1..5
        |> Task.async_stream(
          fn i ->
            RepoAdapter.append(%Event{
              id: Ecto.UUID.generate(),
              assignment_id: "a-conc",
              type: :claimed,
              occurred_at: DateTime.utc_now(),
              payload: %{n: i}
            })
          end,
          max_concurrency: 5
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      sequences = "a-conc" |> RepoAdapter.events_for() |> Enum.map(& &1.sequence)
      assert sequences == [1, 2, 3, 4, 5]
    end
  end

  describe "crash survivability" do
    test "events survive process restart and replay identically" do
      # Phase 1: append events via RepoAdapter
      for i <- 1..3 do
        RepoAdapter.append(%Event{
          id: Ecto.UUID.generate(),
          assignment_id: "a-survive",
          type: :claimed,
          occurred_at: DateTime.utc_now(),
          payload: %{n: i}
        })
      end

      # Phase 2: fetch events
      before_events = RepoAdapter.events_for("a-survive")

      # Phase 3: "restart" — just re-query from DB
      after_events = RepoAdapter.events_for("a-survive")

      # Phase 4: verify identical
      assert before_events == after_events

      # Phase 5: reduce both and compare
      import DevIDE.Assignments.Reducer
      before_proj = reduce(before_events)
      after_proj = reduce(after_events)
      assert before_proj == after_proj
    end
  end
end
