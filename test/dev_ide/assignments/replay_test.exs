defmodule DevIDE.Assignments.ReplayTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Event
  alias DevIDE.Assignments.EventStore.RepoAdapter
  alias DevIDE.Assignments.ProjectionStore.MemoryAdapter
  alias DevIDE.Assignments.Replay
  alias DevIde.Repo

  setup do
    # Clean slate: empty database events and empty projection cache
    Repo.delete_all(Assignments.EventRow)
    MemoryAdapter.clear()

    # Route Replay through the RepoAdapter for events, MemoryAdapter for projections
    Application.put_env(:dev_ide, :assignment_event_store_adapter, RepoAdapter)
    Application.put_env(:dev_ide, :assignment_projection_store_adapter, MemoryAdapter)

    on_exit(fn ->
      Application.put_env(
        :dev_ide,
        :assignment_event_store_adapter,
        Assignments.EventStore.MemoryAdapter
      )

      Application.put_env(:dev_ide, :assignment_projection_store_adapter, MemoryAdapter)
    end)

    :ok
  end

  describe "verify_all/0" do
    test "returns empty report when no events exist" do
      report = Replay.verify_all()

      assert report.total == 0
      assert report.consistent == 0
      assert report.inconsistent == 0
      assert report.missing == 0
      assert report.details == []
    end

    test "reports missing when events exist but cache is empty" do
      append_events("a-1", [:created, :claimed, :started])

      report = Replay.verify_all()

      assert report.total == 1
      assert report.consistent == 0
      assert report.inconsistent == 0
      assert report.missing == 1

      [detail] = report.details
      assert detail.assignment_id == "a-1"
      assert detail.status == :missing
      assert detail.event_count == 3
      assert detail.from_cache == nil
      assert detail.from_events.state == "running"
    end

    test "reports consistent when cache matches events" do
      append_events("a-1", [:created, :claimed, :started])
      :ok = Replay.rebuild_all()

      report = Replay.verify_all()

      assert report.total == 1
      assert report.consistent == 1
      assert report.inconsistent == 0
      assert report.missing == 0

      [detail] = report.details
      assert detail.status == :consistent
      assert detail.from_events == detail.from_cache
    end

    test "reports inconsistent when cache is corrupted" do
      append_events("a-1", [:created, :claimed, :started])
      :ok = Replay.rebuild_all()

      # Corrupt the cache manually
      {:ok, cached} = MemoryAdapter.get("a-1")
      corrupted = %{cached | state: "completed"}
      :ok = MemoryAdapter.put("a-1", corrupted)

      report = Replay.verify_all()

      assert report.total == 1
      assert report.consistent == 0
      assert report.inconsistent == 1
      assert report.missing == 0

      [detail] = report.details
      assert detail.status == :inconsistent
      assert detail.from_events.state == "running"
      assert detail.from_cache.state == "completed"
    end

    test "handles multiple assignments independently" do
      append_events("a-1", [:created, :claimed])
      append_events("a-2", [:created])
      append_events("a-3", [:created, :claimed, :started, :completed])

      :ok = Replay.rebuild_all()

      # Corrupt a-2 only
      {:ok, cached} = MemoryAdapter.get("a-2")
      corrupted = %{cached | state: "running"}
      :ok = MemoryAdapter.put("a-2", corrupted)

      report = Replay.verify_all()

      assert report.total == 3
      assert report.consistent == 2
      assert report.inconsistent == 1
      assert report.missing == 0

      states = Map.new(report.details, &{&1.assignment_id, &1.status})
      assert states["a-1"] == :consistent
      assert states["a-2"] == :inconsistent
      assert states["a-3"] == :consistent
    end
  end

  describe "verify/1" do
    test "returns error when no events exist" do
      assert Replay.verify("nonexistent") == {:error, :no_events}
    end

    test "returns consistent result" do
      append_events("a-1", [:created, :claimed])
      :ok = Replay.rebuild_all()

      assert {:ok, result} = Replay.verify("a-1")
      assert result.status == :consistent
      assert result.event_count == 2
      assert result.from_events.state == "claimed"
      assert result.from_cache.state == "claimed"
    end

    test "returns missing result when cache is absent" do
      append_events("a-1", [:created])

      assert {:ok, result} = Replay.verify("a-1")
      assert result.status == :missing
      assert result.from_cache == nil
    end
  end

  describe "repair/1" do
    test "rebuilds a single projection from events" do
      append_events("a-1", [:created, :claimed, :started])

      assert MemoryAdapter.get("a-1") == :error

      assert {:ok, projection} = Replay.repair("a-1")
      assert projection.state == "running"

      assert {:ok, cached} = MemoryAdapter.get("a-1")
      assert cached.state == "running"
    end

    test "returns error when no events exist" do
      assert Replay.repair("nonexistent") == {:error, :no_events}
    end

    test "overwrites a corrupted projection" do
      append_events("a-1", [:created, :claimed])
      :ok = Replay.rebuild_all()

      # Corrupt cache
      {:ok, cached} = MemoryAdapter.get("a-1")
      corrupted = %{cached | state: "running"}
      :ok = MemoryAdapter.put("a-1", corrupted)

      # Repair fixes it
      assert {:ok, projection} = Replay.repair("a-1")
      assert projection.state == "claimed"

      assert {:ok, fixed} = MemoryAdapter.get("a-1")
      assert fixed.state == "claimed"
    end
  end

  describe "rebuild_all/0 and repair_all/0" do
    test "rebuild_all restores projections after cache loss" do
      append_events("a-1", [:created, :claimed, :started])
      append_events("a-2", [:created, :claimed, :completed])

      # First build
      :ok = Replay.rebuild_all()

      assert {:ok, p1} = MemoryAdapter.get("a-1")
      assert p1.state == "running"

      assert {:ok, p2} = MemoryAdapter.get("a-2")
      assert p2.state == "completed"

      # Simulate restart: clear projection cache but keep events
      :ok = MemoryAdapter.clear()

      assert MemoryAdapter.get("a-1") == :error
      assert MemoryAdapter.get("a-2") == :error

      # Rebuild from durable events
      :ok = Replay.rebuild_all()

      assert {:ok, restored1} = MemoryAdapter.get("a-1")
      assert restored1.state == "running"

      assert {:ok, restored2} = MemoryAdapter.get("a-2")
      assert restored2.state == "completed"
    end

    test "repair_all is an alias for rebuild_all" do
      append_events("a-1", [:created])

      :ok = Replay.repair_all()

      assert {:ok, p} = MemoryAdapter.get("a-1")
      assert p.state == "requested"
    end

    test "rebuild_all overwrites stale projections with current events" do
      append_events("a-1", [:created, :claimed])
      :ok = Replay.rebuild_all()

      # Append more events directly to store (bypassing Assignments API)
      RepoAdapter.append(%Event{
        id: Ecto.UUID.generate(),
        assignment_id: "a-1",
        type: :started,
        occurred_at: DateTime.utc_now(),
        payload: %{}
      })

      # Cache still shows "claimed" because we bypassed projection update
      assert {:ok, stale} = MemoryAdapter.get("a-1")
      assert stale.state == "claimed"

      # Rebuild brings cache up to date
      :ok = Replay.rebuild_all()

      assert {:ok, current} = MemoryAdapter.get("a-1")
      assert current.state == "running"
    end
  end

  describe "crash survivability" do
    test "events survive full restart cycle and replay rebuilds identically" do
      # Phase 1: create events
      append_events("a-survive", [:created, :claimed, :started, :completed])
      :ok = Replay.rebuild_all()

      {:ok, before_restart} = MemoryAdapter.get("a-survive")

      # Phase 2: simulate crash — clear cache only
      :ok = MemoryAdapter.clear()

      # Phase 3: replay rebuilds from durable events
      :ok = Replay.rebuild_all()

      {:ok, after_restart} = MemoryAdapter.get("a-survive")

      # Phase 4: verify identical
      assert before_restart == after_restart
      assert after_restart.state == "completed"
    end
  end

  ## Helpers

  defp append_events(assignment_id, event_types) do
    for {type, seq} <- Enum.with_index(event_types, 1) do
      payload =
        case type do
          :created -> %{workspace_id: "ws-1"}
          :claimed -> %{lease_owner: "runner-1", lease_expires_at: future_date()}
          _ -> %{}
        end

      {:ok, _} =
        RepoAdapter.append(%Event{
          id: Ecto.UUID.generate(),
          assignment_id: assignment_id,
          type: type,
          sequence: seq,
          occurred_at: DateTime.utc_now(),
          payload: payload
        })
    end

    :ok
  end

  defp future_date do
    DateTime.utc_now() |> DateTime.add(3600, :second)
  end
end
