defmodule DevIDE.Fleet.PlacementTest do
  use ExUnit.Case, async: false

  alias DevIDE.Fleet
  alias DevIDE.Fleet.{AssignmentRequirements, Placement, Policy, Queue}

  setup do
    Fleet.clear()
    Queue.clear()
    :ok
  end

  describe "AssignmentRequirements struct" do
    test "constructs with defaults" do
      req = AssignmentRequirements.new(%{})
      assert req.capabilities == []
      assert req.isolation == :shared
      assert req.priority == :normal
      assert req.anti_affinity == []
      assert req.workspace_affinity == nil
      assert req.concurrency_group == nil
      assert req.max_runtime_ms == nil
    end

    test "constructs with overrides" do
      req =
        AssignmentRequirements.new(
          capabilities: ["gpu", "docker"],
          isolation: :dedicated,
          priority: :high,
          workspace_affinity: "ws-1"
        )

      assert req.capabilities == ["gpu", "docker"]
      assert req.isolation == :dedicated
      assert req.priority == :high
      assert req.workspace_affinity == "ws-1"
    end
  end

  describe "Queue operations" do
    test "enqueue adds assignment to queue" do
      req = AssignmentRequirements.new(%{})
      :ok = Queue.enqueue("a-1", req)

      assert Queue.count() == 1
      assert Queue.queued?("a-1")
    end

    test "peek returns next entry without removing" do
      req = AssignmentRequirements.new(%{})
      :ok = Queue.enqueue("a-1", req)

      entry = Queue.peek()
      assert entry.assignment_id == "a-1"
      assert Queue.count() == 1
    end

    test "dequeue removes and returns next entry" do
      req = AssignmentRequirements.new(%{})
      :ok = Queue.enqueue("a-1", req)

      entry = Queue.dequeue()
      assert entry.assignment_id == "a-1"
      assert Queue.count() == 0
      assert Queue.peek() == nil
    end

    test "enqueue deduplicates same assignment" do
      req = AssignmentRequirements.new(%{})
      :ok = Queue.enqueue("a-1", req)
      :ok = Queue.enqueue("a-1", req)

      assert Queue.count() == 1
    end

    test "remove deletes assignment from queue" do
      req = AssignmentRequirements.new(%{})
      :ok = Queue.enqueue("a-1", req)
      :ok = Queue.remove("a-1")

      assert Queue.count() == 0
      refute Queue.queued?("a-1")
    end

    test "orders by priority then enqueue time" do
      low = AssignmentRequirements.new(priority: :low)
      normal = AssignmentRequirements.new(priority: :normal)
      high = AssignmentRequirements.new(priority: :high)

      :ok = Queue.enqueue("a-low", low)
      :ok = Queue.enqueue("a-high", high)
      :ok = Queue.enqueue("a-normal", normal)

      entries = Queue.list()
      ids = Enum.map(entries, & &1.assignment_id)
      assert ids == ["a-high", "a-normal", "a-low"]
    end

    test "FIFO within same priority" do
      first = AssignmentRequirements.new(priority: :normal)
      second = AssignmentRequirements.new(priority: :normal)

      :ok = Queue.enqueue("a-first", first)
      Process.sleep(10)
      :ok = Queue.enqueue("a-second", second)

      entries = Queue.list()
      ids = Enum.map(entries, & &1.assignment_id)
      assert ids == ["a-first", "a-second"]
    end

    test "list_by_priority filters correctly" do
      low = AssignmentRequirements.new(priority: :low)
      high = AssignmentRequirements.new(priority: :high)

      :ok = Queue.enqueue("a-low", low)
      :ok = Queue.enqueue("a-high", high)

      assert length(Queue.list_by_priority(:high)) == 1
      assert length(Queue.list_by_priority(:low)) == 1
      assert length(Queue.list_by_priority(:normal)) == 0
    end
  end

  describe "Placement.compute_eligible/2" do
    test "returns empty list when no runners exist" do
      req = AssignmentRequirements.new(capabilities: ["gpu"])
      snapshot = %{runners: []}
      assert Placement.compute_eligible(req, snapshot) == []
    end

    test "filters by required capabilities" do
      {:ok, _} = Fleet.register(%{hostname: "r-gpu", capabilities: ["gpu"]})
      {:ok, _} = Fleet.register(%{hostname: "r-cpu", capabilities: ["cpu"]})

      snapshot = enriched_snapshot()
      req = AssignmentRequirements.new(capabilities: ["gpu"])
      eligible = Placement.compute_eligible(req, snapshot)

      assert length(eligible) == 1
      [runner_id] = eligible
      {:ok, runner} = Fleet.get_runner(runner_id)
      assert runner.hostname == "r-gpu"
    end

    test "filters out busy runners" do
      {:ok, r1} = Fleet.register(%{hostname: "r-1", capabilities: ["docker"]})
      {:ok, r2} = Fleet.register(%{hostname: "r-2", capabilities: ["docker"]})
      {:ok, _} = Fleet.acquire_lease(r1.id, "assignment-1")

      snapshot = enriched_snapshot()
      req = AssignmentRequirements.new(capabilities: ["docker"])
      eligible = Placement.compute_eligible(req, snapshot)

      assert length(eligible) == 1
      assert hd(eligible) == r2.id
    end

    test "filters out offline runners" do
      {:ok, r1} = Fleet.register(%{hostname: "r-1", capabilities: []})
      {:ok, r2} = Fleet.register(%{hostname: "r-2", capabilities: []})
      Fleet.mark_offline([r2.id])

      snapshot = enriched_snapshot()
      req = AssignmentRequirements.new(capabilities: [])
      eligible = Placement.compute_eligible(req, snapshot)

      assert length(eligible) == 1
      assert hd(eligible) == r1.id
    end

    test "rejects runners in anti_affinity" do
      {:ok, r1} = Fleet.register(%{hostname: "r-1", capabilities: []})
      {:ok, _} = Fleet.register(%{hostname: "r-2", capabilities: []})

      snapshot = enriched_snapshot()
      req = AssignmentRequirements.new(capabilities: [], anti_affinity: [r1.id])
      eligible = Placement.compute_eligible(req, snapshot)

      assert r1.id not in eligible
    end

    test "dedicated isolation requires no active leases" do
      {:ok, r1} = Fleet.register(%{hostname: "r-1", capabilities: []})
      {:ok, r2} = Fleet.register(%{hostname: "r-2", capabilities: []})
      {:ok, _} = Fleet.acquire_lease(r1.id, "assignment-1")

      snapshot = enriched_snapshot()
      req = AssignmentRequirements.new(capabilities: [], isolation: :dedicated)
      eligible = Placement.compute_eligible(req, snapshot)

      assert length(eligible) == 1
      assert hd(eligible) == r2.id
    end

    test "shared isolation allows runners with leases" do
      {:ok, r1} = Fleet.register(%{hostname: "r-1", capabilities: []})
      {:ok, _} = Fleet.acquire_lease(r1.id, "assignment-1")
      :ok = Fleet.release_lease("assignment-1")

      snapshot = enriched_snapshot()
      req = AssignmentRequirements.new(capabilities: [], isolation: :shared)
      eligible = Placement.compute_eligible(req, snapshot)

      # r1 is now idle again
      assert r1.id in eligible
    end

    test "sorts deterministically by registration time" do
      {:ok, r1} = Fleet.register(%{hostname: "r-1"})
      Process.sleep(20)
      {:ok, r2} = Fleet.register(%{hostname: "r-2"})

      snapshot = enriched_snapshot()
      req = AssignmentRequirements.new(capabilities: [])
      eligible = Placement.compute_eligible(req, snapshot)

      assert eligible == [r1.id, r2.id]
    end
  end

  describe "Placement.first_eligible/2" do
    test "returns first matching runner" do
      {:ok, r1} = Fleet.register(%{hostname: "r-1", capabilities: ["docker"]})
      {:ok, _} = Fleet.register(%{hostname: "r-2", capabilities: ["docker"]})

      snapshot = enriched_snapshot()
      req = AssignmentRequirements.new(capabilities: ["docker"])

      assert Placement.first_eligible(req, snapshot) == r1.id
    end

    test "returns nil when no runners match" do
      snapshot = enriched_snapshot()
      req = AssignmentRequirements.new(capabilities: ["nonexistent"])

      assert Placement.first_eligible(req, snapshot) == nil
    end
  end

  describe "Policy.choose/3" do
    test ":first returns first element" do
      assert Policy.choose(["a", "b", "c"], :first) == "a"
    end

    test ":first returns nil for empty list" do
      assert Policy.choose([], :first) == nil
    end

    test ":round_robin cycles through candidates" do
      assert Policy.choose(["a", "b", "c"], :round_robin) == "a"
      assert Policy.choose(["a", "b", "c"], :round_robin, last_chosen: "a") == "b"
      assert Policy.choose(["a", "b", "c"], :round_robin, last_chosen: "c") == "a"
    end

    test ":least_loaded chooses runner with fewest leases" do
      assert Policy.choose(["a", "b", "c"], :least_loaded,
               load_map: %{"a" => 3, "b" => 1, "c" => 2}
             ) == "b"
    end

    test ":least_loaded falls back to first when load data missing" do
      assert Policy.choose(["a", "b"], :least_loaded, load_map: %{}) == "a"
    end
  end

  describe "PlacementPass" do
    test "trigger with empty queue does nothing" do
      :ok = Fleet.PlacementPass.trigger()
      result = Fleet.PlacementPass.last_result()

      assert result.total_attempted == 0
      assert result.placed == []
    end

    test "places assignment when eligible runner exists" do
      {:ok, runner} = Fleet.register(%{hostname: "r-1", capabilities: ["docker"]})

      req = AssignmentRequirements.new(capabilities: ["docker"])
      :ok = Queue.enqueue("a-1", req)

      :ok = Fleet.PlacementPass.trigger()
      result = Fleet.PlacementPass.last_result()

      assert result.total_attempted == 1
      assert length(result.placed) == 1

      placed = hd(result.placed)
      assert placed.assignment_id == "a-1"
      assert placed.runner_id == runner.id

      assert Queue.count() == 0
      assert {:ok, lease} = Fleet.get_lease("a-1")
      assert lease.state == :active
    end

    test "skips assignment when no eligible runner" do
      req = AssignmentRequirements.new(capabilities: ["gpu"])
      :ok = Queue.enqueue("a-1", req)

      :ok = Fleet.PlacementPass.trigger()
      result = Fleet.PlacementPass.last_result()

      assert result.total_attempted == 1
      assert result.skipped == ["no_eligible"]
      assert result.placed == []

      # Assignment remains in queue
      assert Queue.count() == 1
    end

    test "places multiple assignments in priority order" do
      {:ok, _r1} = Fleet.register(%{hostname: "r-1", capabilities: []})
      {:ok, _r2} = Fleet.register(%{hostname: "r-2", capabilities: []})

      low = AssignmentRequirements.new(priority: :low)
      high = AssignmentRequirements.new(priority: :high)

      :ok = Queue.enqueue("a-low", low)
      :ok = Queue.enqueue("a-high", high)

      :ok = Fleet.PlacementPass.trigger()
      result = Fleet.PlacementPass.last_result()

      assert result.total_attempted == 2
      assert length(result.placed) == 2

      # High priority should be placed first
      [first, second] = result.placed
      assert first.assignment_id == "a-high"
      assert second.assignment_id == "a-low"
    end

    test "leaves unplaced assignment in queue for next pass" do
      req = AssignmentRequirements.new(capabilities: ["gpu"])
      :ok = Queue.enqueue("a-1", req)

      :ok = Fleet.PlacementPass.trigger()
      first_result = Fleet.PlacementPass.last_result()
      assert first_result.skipped == ["no_eligible"]

      # Now register a GPU runner
      {:ok, _} = Fleet.register(%{hostname: "r-gpu", capabilities: ["gpu"]})

      :ok = Fleet.PlacementPass.trigger()
      second_result = Fleet.PlacementPass.last_result()

      assert length(second_result.placed) == 1
      assert hd(second_result.placed).assignment_id == "a-1"
    end
  end

  ## Helpers

  defp enriched_snapshot do
    runners = Fleet.list_runners()

    active_leases_by_runner =
      Fleet.active_leases()
      |> Enum.group_by(& &1.runner_id)
      |> Map.new(fn {id, leases} -> {id, leases} end)

    Map.merge(Fleet.snapshot(), %{
      runners: runners,
      active_leases_by_runner: active_leases_by_runner
    })
  end
end
