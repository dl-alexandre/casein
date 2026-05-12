defmodule DevIDE.FleetTest do
  use ExUnit.Case, async: false

  alias DevIDE.Fleet
  alias DevIDE.Fleet.{Lease, Runner}

  setup do
    Fleet.clear()
    :ok
  end

  describe "register/1" do
    test "registers a new runner" do
      assert {:ok, runner} =
               Fleet.register(%{hostname: "runner-1", capabilities: ["linux", "docker"]})

      assert runner.hostname == "runner-1"
      assert "linux" in runner.capabilities
      assert runner.state == :online
      assert runner.last_heartbeat_at != nil
    end

    test "rejects duplicate runner ids" do
      id = Ecto.UUID.generate()

      assert {:ok, _} =
               Fleet.register(%{id: id, hostname: "runner-1", capabilities: []})

      assert {:error, :duplicate_id} =
               Fleet.register(%{id: id, hostname: "runner-2", capabilities: []})
    end

    test "auto-generates id when not provided" do
      assert {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      assert is_binary(runner.id)
      assert String.length(runner.id) == 36
    end
  end

  describe "heartbeat/1" do
    test "updates last_heartbeat_at" do
      assert {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      before = runner.last_heartbeat_at
      Process.sleep(10)

      assert {:ok, updated} = Fleet.heartbeat(runner.id)
      assert DateTime.compare(updated.last_heartbeat_at, before) == :gt
    end

    test "returns error for unknown runner" do
      assert :error = Fleet.heartbeat("nonexistent")
    end

    test "revives offline runner back to online" do
      assert {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      Fleet.mark_offline([runner.id])

      assert {:ok, offline} = Fleet.get_runner(runner.id)
      assert offline.state == :offline

      assert {:ok, revived} = Fleet.heartbeat(runner.id)
      assert revived.state == :online
    end
  end

  describe "unregister/1" do
    test "removes runner and releases all leases" do
      assert {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      assert {:ok, lease} = Fleet.acquire_lease(runner.id, "assignment-1")
      assert lease.state == :active

      :ok = Fleet.unregister(runner.id)

      assert Fleet.get_runner(runner.id) == :error
      assert Fleet.get_lease("assignment-1") == :error
    end
  end

  describe "list_runners/0 and queries" do
    test "returns all registered runners" do
      Fleet.register(%{hostname: "runner-1"})
      Fleet.register(%{hostname: "runner-2"})

      runners = Fleet.list_runners()
      assert length(runners) == 2
    end

    test "filters by state" do
      {:ok, r1} = Fleet.register(%{hostname: "runner-1"})
      {:ok, r2} = Fleet.register(%{hostname: "runner-2"})
      {:ok, _} = Fleet.acquire_lease(r1.id, "assignment-1")
      {:ok, _} = Fleet.acquire_lease(r2.id, "assignment-2")
      :ok = Fleet.release_lease("assignment-1")

      idle = Fleet.runners_by_state(:idle)
      assert length(idle) == 1
      assert hd(idle).id == r1.id

      busy = Fleet.runners_by_state(:busy)
      assert length(busy) == 1
      assert hd(busy).id == r2.id
    end

    test "filters by capability" do
      Fleet.register(%{hostname: "runner-1", capabilities: ["gpu"]})
      Fleet.register(%{hostname: "runner-2", capabilities: ["docker"]})
      Fleet.register(%{hostname: "runner-3", capabilities: ["gpu", "docker"]})

      gpu_runners = Fleet.runners_with_capability("gpu")
      assert length(gpu_runners) == 2

      docker_runners = Fleet.runners_with_capability("docker")
      assert length(docker_runners) == 2
    end
  end

  describe "idle_runners/0 and online_runners/0" do
    test "idle_runners returns only idle runners" do
      {:ok, r1} = Fleet.register(%{hostname: "runner-1"})
      {:ok, r2} = Fleet.register(%{hostname: "runner-2"})
      {:ok, _} = Fleet.acquire_lease(r1.id, "assignment-1")
      {:ok, _} = Fleet.acquire_lease(r2.id, "assignment-2")
      :ok = Fleet.release_lease("assignment-1")

      idle = Fleet.idle_runners()
      assert length(idle) == 1
      assert hd(idle).id == r1.id
    end

    test "online_runners excludes offline/stale" do
      {:ok, r1} = Fleet.register(%{hostname: "runner-1"})
      {:ok, r2} = Fleet.register(%{hostname: "runner-2"})
      Fleet.mark_offline([r2.id])

      online = Fleet.online_runners()
      assert length(online) == 1
      assert hd(online).id == r1.id
    end
  end

  describe "acquire_lease/3" do
    test "creates active lease and marks runner busy" do
      {:ok, runner} = Fleet.register(%{hostname: "runner-1"})

      assert {:ok, lease} = Fleet.acquire_lease(runner.id, "assignment-1")
      assert lease.assignment_id == "assignment-1"
      assert lease.runner_id == runner.id
      assert lease.state == :active
      assert lease.expires_at != nil

      assert {:ok, updated_runner} = Fleet.get_runner(runner.id)
      assert updated_runner.state == :busy
      assert updated_runner.active_assignment_id == "assignment-1"
    end

    test "rejects lease for unknown runner" do
      assert {:error, :runner_not_found} = Fleet.acquire_lease("bad", "assignment-1")
    end

    test "rejects lease for busy runner" do
      {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      {:ok, _} = Fleet.acquire_lease(runner.id, "assignment-1")

      assert {:error, :runner_busy} = Fleet.acquire_lease(runner.id, "assignment-2")
    end

    test "rejects duplicate lease for same assignment" do
      {:ok, r1} = Fleet.register(%{hostname: "runner-1"})
      {:ok, r2} = Fleet.register(%{hostname: "runner-2"})
      {:ok, _} = Fleet.acquire_lease(r1.id, "assignment-1")

      assert {:error, :already_leased} = Fleet.acquire_lease(r2.id, "assignment-1")
    end

    test "accepts custom lease duration" do
      {:ok, runner} = Fleet.register(%{hostname: "runner-1"})

      assert {:ok, lease} =
               Fleet.acquire_lease(runner.id, "assignment-1", duration_ms: 5_000)

      # Should expire ~5 seconds from now
      now = DateTime.utc_now()
      diff = DateTime.diff(lease.expires_at, now, :millisecond)
      assert diff >= 4_900 and diff <= 5_100
    end
  end

  describe "release_lease/1" do
    test "releases lease and marks runner idle" do
      {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      {:ok, _} = Fleet.acquire_lease(runner.id, "assignment-1")

      assert :ok = Fleet.release_lease("assignment-1")

      assert Fleet.get_lease("assignment-1") == :error

      assert {:ok, updated} = Fleet.get_runner(runner.id)
      assert updated.state == :idle
      assert updated.active_assignment_id == nil
    end

    test "returns error for unknown assignment" do
      assert :error = Fleet.release_lease("nonexistent")
    end
  end

  describe "revoke_lease/1" do
    test "revokes lease and marks runner idle" do
      {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, "assignment-1")
      assert lease.state == :active

      assert :ok = Fleet.revoke_lease("assignment-1")

      # After revoke, lease is removed from active index
      assert :error = Fleet.get_lease("assignment-1")

      assert {:ok, updated} = Fleet.get_runner(runner.id)
      assert updated.state == :idle
    end
  end

  describe "expire_leases/1" do
    test "expires leases past their deadline" do
      {:ok, runner} = Fleet.register(%{hostname: "runner-1"})

      # Create a lease that expires immediately
      {:ok, _} =
        Fleet.acquire_lease(runner.id, "assignment-past", duration_ms: 1)

      # Wait for it to expire
      Process.sleep(10)

      {:ok, fresh_runner} = Fleet.register(%{hostname: "runner-2"})
      {:ok, _} = Fleet.acquire_lease(fresh_runner.id, "assignment-future")

      expired = Fleet.expire_leases(DateTime.utc_now())
      assert length(expired) == 1
      assert hd(expired).assignment_id == "assignment-past"

      # Fresh lease should still be active
      assert {:ok, still_active} = Fleet.get_lease("assignment-future")
      assert still_active.state == :active

      # Runner should be idle after expiry
      assert {:ok, updated} = Fleet.get_runner(runner.id)
      assert updated.state == :idle
    end
  end

  describe "detect_stale/1" do
    test "marks runners with old heartbeats as offline" do
      {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      # Don't heartbeat
      Process.sleep(50)

      stale = Fleet.detect_stale(10)
      assert length(stale) == 1
      assert hd(stale).id == runner.id

      assert {:ok, offline} = Fleet.get_runner(runner.id)
      assert offline.state == :offline
    end

    test "ignores recently heartbeated runners" do
      {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      Fleet.heartbeat(runner.id)

      assert Fleet.detect_stale(60_000) == []
      assert {:ok, still_online} = Fleet.get_runner(runner.id)
      assert still_online.state == :online
    end
  end

  describe "topology queries" do
    test "assignments_for_runner/1" do
      {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      {:ok, _} = Fleet.acquire_lease(runner.id, "assignment-1")
      :ok = Fleet.release_lease("assignment-1")
      {:ok, _} = Fleet.acquire_lease(runner.id, "assignment-2")

      assignments = Fleet.assignments_for_runner(runner.id)
      assert length(assignments) == 1
      assert "assignment-2" in assignments
    end

    test "runner_for_assignment/1" do
      {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      {:ok, _} = Fleet.acquire_lease(runner.id, "assignment-1")

      assert {:ok, runner_id} = Fleet.runner_for_assignment("assignment-1")
      assert runner_id == runner.id

      assert :error = Fleet.runner_for_assignment("nonexistent")
    end

    test "runner_for_assignment returns error for released lease" do
      {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      {:ok, _} = Fleet.acquire_lease(runner.id, "assignment-1")
      Fleet.release_lease("assignment-1")

      assert :error = Fleet.runner_for_assignment("assignment-1")
    end
  end

  describe "snapshot/0" do
    test "returns fleet-wide counts" do
      {:ok, r1} = Fleet.register(%{hostname: "runner-1", capabilities: ["gpu"]})
      {:ok, r2} = Fleet.register(%{hostname: "runner-2", capabilities: ["gpu", "docker"]})
      {:ok, _} = Fleet.acquire_lease(r1.id, "assignment-1")
      Fleet.mark_offline([r2.id])

      snap = Fleet.snapshot()

      assert snap.total_runners == 2
      assert snap.online == 1
      assert snap.idle == 0
      assert snap.busy == 1
      assert snap.offline == 1
      assert snap.active_leases == 1
      assert snap.capabilities == %{"docker" => 1, "gpu" => 2}
    end
  end

  describe "clear/0" do
    test "removes all runners and leases" do
      {:ok, runner} = Fleet.register(%{hostname: "runner-1"})
      {:ok, _} = Fleet.acquire_lease(runner.id, "assignment-1")

      :ok = Fleet.clear()

      assert Fleet.list_runners() == []
      assert Fleet.list_leases() == []
      assert Fleet.active_leases() == []
    end
  end

  describe "Runner struct" do
    test "enforces required fields" do
      assert_raise ArgumentError, fn ->
        struct!(Runner, %{})
      end
    end

    test "constructs with required fields" do
      runner = %Runner{id: "r-1", hostname: "host-1"}
      assert runner.id == "r-1"
      assert runner.hostname == "host-1"
      assert runner.capabilities == nil
      assert runner.metadata == %{}
    end
  end

  describe "Lease struct" do
    test "enforces required fields" do
      assert_raise ArgumentError, fn ->
        struct!(Lease, %{})
      end
    end

    test "defaults state to active" do
      now = DateTime.utc_now()

      lease = %Lease{
        id: "l-1",
        assignment_id: "a-1",
        runner_id: "r-1",
        acquired_at: now,
        expires_at: now
      }

      assert lease.state == :active
      assert lease.released_at == nil
    end
  end
end
