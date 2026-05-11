defmodule DevIDE.Runners.EctoAdapterTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Devbox.Workspace
  alias DevIDE.Runners
  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    DevIDE.Runners.EctoAdapter.clear()
    DevIDE.Audit.MemoryAdapter.clear()

    prev_runner = Application.get_env(:dev_ide, :runner_protocol_adapter)
    Application.put_env(:dev_ide, :runner_protocol_adapter, DevIDE.Runners.EctoAdapter)

    on_exit(fn ->
      MemoryAdapter.clear()
      DevIDE.Runners.EctoAdapter.clear()

      if prev_runner,
        do: Application.put_env(:dev_ide, :runner_protocol_adapter, prev_runner),
        else: Application.delete_env(:dev_ide, :runner_protocol_adapter)
    end)

    seed_workspace("ws-ecto")
    :ok
  end

  test "assignments and append-only reports are persisted through the Ecto adapter" do
    {:ok, queued} = Runners.enqueue_command("ws-ecto", "precommit")

    {:ok, claimed} =
      Runners.poll(%{
        "runner_id" => "runner-db",
        "capabilities" => ["workspace-command:v1"],
        "workspace_ids" => ["ws-ecto"]
      })

    assert claimed.id == queued.id
    assert claimed.claimed_by == "runner-db"
    assert claimed.action.argv == ["mix", "precommit"]

    {:ok, first} =
      Runners.append_report(claimed.id, %{
        "claim_token" => claimed.claim_token,
        "report_id" => "db-progress-1",
        "event" => "progress",
        "message" => "running precommit"
      })

    {:ok, duplicate_first} =
      Runners.append_report(claimed.id, %{
        "claim_token" => claimed.claim_token,
        "report_id" => "db-progress-1",
        "event" => "progress",
        "message" => "running precommit"
      })

    assert duplicate_first.id == first.id

    {:ok, completed, second} =
      Runners.fail(claimed.id, %{
        "claim_token" => claimed.claim_token,
        "report_id" => "db-terminal-1",
        "reason" => "test_failure",
        "evidence" => %{"exit_code" => 2, "log_ref" => "runner://log/1"}
      })

    {:ok, duplicate_completed, duplicate_second} =
      Runners.fail(claimed.id, %{
        "claim_token" => claimed.claim_token,
        "report_id" => "db-terminal-1",
        "reason" => "test_failure",
        "evidence" => %{"exit_code" => 2, "log_ref" => "runner://log/1"}
      })

    assert completed.status == "failed"
    assert duplicate_completed.status == "failed"
    assert first.position == 1
    assert second.position == 2
    assert duplicate_second.id == second.id

    {:ok, replay} = Runners.replay(claimed.id)
    assert replay.assignment.status == "failed"
    assert Enum.map(replay.reports, & &1.event) == ["progress", "failed"]
  end

  defp seed_workspace(id) do
    {:ok, _} =
      State.sync_from_manager(%Workspace{
        id: id,
        name: "ecto",
        user: "alice",
        branch: "main",
        type: :v3,
        status: :running,
        path: "/tmp/#{id}",
        raw: %{"id" => id}
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
