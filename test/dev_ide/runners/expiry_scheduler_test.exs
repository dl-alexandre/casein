defmodule DevIDE.Runners.ExpirySchedulerTest do
  use DevIde.DataCase, async: false
  use Oban.Testing, repo: DevIde.Repo

  alias DevIDE.Workspace
  alias DevIDE.Runners
  alias DevIDE.Runners.ExpireLeasesWorker
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

  test "perform enqueues the next maintenance tick" do
    assert :ok = perform_job(ExpireLeasesWorker, %{})
    assert_enqueued(worker: ExpireLeasesWorker, queue: :maintenance)
  end

  test "transitions claimed assignments with expired leases to 'expired'" do
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

    Process.sleep(35)

    assert :ok = perform_job(ExpireLeasesWorker, %{})

    {:ok, replay} = Runners.replay(claimed.id)

    assert replay.assignment.status == "expired",
           "expected lease to be expired by worker; got: #{inspect(replay.assignment.status)}"
  end

  test "perform without crashing when there are no leases to expire" do
    assert :ok = perform_job(ExpireLeasesWorker, %{})
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
