defmodule DevIDE.Runners.ExpirySchedulerTest do
  use ExUnit.Case, async: false

  alias DevIDE.Workspace
  alias DevIDE.Runners
  alias DevIDE.Runners.ExpiryScheduler
  alias DevIDE.Workspaces.{DbIsolation, State}

  setup do
    prev_lease = Application.get_env(:dev_ide, :runner_assignment_lease_ms)
    prev_adapter = Application.get_env(:dev_ide, :runner_protocol_adapter)

    Application.put_env(:dev_ide, :runner_protocol_adapter, DevIDE.Runners.MemoryAdapter)
    Runners.clear()

    on_exit(fn ->
      if prev_lease,
        do: Application.put_env(:dev_ide, :runner_assignment_lease_ms, prev_lease),
        else: Application.delete_env(:dev_ide, :runner_assignment_lease_ms)

      if prev_adapter,
        do: Application.put_env(:dev_ide, :runner_protocol_adapter, prev_adapter),
        else: Application.delete_env(:dev_ide, :runner_protocol_adapter)

      Runners.clear()
    end)

    :ok
  end

  test "stays alive across multiple ticks" do
    {:ok, pid} = ExpiryScheduler.start_link(interval_ms: 20, name: nil)
    Process.sleep(120)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "transitions claimed assignments with expired leases to 'expired'" do
    # Very short lease so the scheduler can pick it up within the test.
    Application.put_env(:dev_ide, :runner_assignment_lease_ms, 30)

    seed_workspace("ws-expire")

    {:ok, _queued} = Runners.enqueue_command("ws-expire", "test", requested_by: "test-jx")

    {:ok, claimed} =
      Runners.poll(%{
        "protocol" => Runners.protocol(),
        "runner_id" => "runner-expiry",
        "capabilities" => ["workspace-command:v1"],
        "workspace_ids" => ["ws-expire"]
      })

    assert claimed.status == "claimed"

    {:ok, sched} = ExpiryScheduler.start_link(interval_ms: 25, name: nil)

    # Lease is 30ms; first tick after 25ms doesn't catch it but the
    # second (at ~50ms) does. Wait 200ms to be generous.
    Process.sleep(200)

    {:ok, replay} = Runners.replay(claimed.id)

    assert replay.assignment.status == "expired",
           "expected lease to be expired by scheduler ticks; got: #{inspect(replay.assignment.status)}"

    GenServer.stop(sched)
  end

  test "ticks without crashing when there are no leases to expire" do
    # Don't enqueue anything. Scheduler should still happily tick.
    {:ok, sched} = ExpiryScheduler.start_link(interval_ms: 15, name: nil)
    Process.sleep(80)
    assert Process.alive?(sched)
    GenServer.stop(sched)
  end

  defp seed_workspace(id) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: "alpha-#{id}",
        user: "alice",
        branch: "main",
        status: :running,
        path: "/tmp/#{id}",
        metadata: %{"id" => id}
      })

    {:ok, _} =
      State.persist_isolation(id, %DbIsolation{
        isolation: :local,
        source: :env_file,
        summary: "local",
        detected_at: DateTime.utc_now()
      })
  end
end
