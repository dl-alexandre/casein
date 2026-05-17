defmodule DevIDE.Runners.ProtocolTest do
  use ExUnit.Case, async: false

  alias DevIDE.Workspace
  alias DevIDE.Runners
  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    Runners.clear()
    DevIDE.Audit.MemoryAdapter.clear()

    prev_runner = Application.get_env(:dev_ide, :runner_protocol_adapter)
    Application.put_env(:dev_ide, :runner_protocol_adapter, DevIDE.Runners.MemoryAdapter)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runners.clear()
      DevIDE.Audit.MemoryAdapter.clear()

      if prev_runner,
        do: Application.put_env(:dev_ide, :runner_protocol_adapter, prev_runner),
        else: Application.delete_env(:dev_ide, :runner_protocol_adapter)
    end)

    seed_workspace("ws-1", :local)
    :ok
  end

  test "runner polls exactly one compatible assignment and reports replayable evidence" do
    {:ok, queued} = Runners.enqueue_command("ws-1", "test", requested_by: "jx")
    assert queued.status == "queued"
    assert queued.safe_action_id == "command:test"

    assert :none =
             Runners.poll(%{
               "runner_id" => "runner-a",
               "capabilities" => ["http-proxy:v1"]
             })

    assert {:ok, claimed} =
             Runners.poll(%{
               "protocol" => Runners.protocol(),
               "runner_id" => "runner-a",
               "capabilities" => ["workspace-command:v1"],
               "workspace_ids" => ["ws-1"]
             })

    assert claimed.status == "claimed"
    assert claimed.claimed_by == "runner-a"
    assert is_binary(claimed.claim_token)
    assert claimed.action.argv == ["mix", "test", "--color"]
    refute claimed.action.argv == ["test"]

    assert :none =
             Runners.poll(%{
               "runner_id" => "runner-a",
               "capabilities" => ["workspace-command:v1"],
               "workspace_ids" => ["ws-1"]
             })

    assert {:ok, report} =
             Runners.append_report(claimed.id, %{
               "claim_token" => claimed.claim_token,
               "event" => "stdout",
               "data" => "mix test output"
             })

    assert report.position == 1
    assert report.event == "stdout"
    assert {:ok, running} = Runners.replay(claimed.id)
    assert running.assignment.status == "running"

    evidence = %{"exit_code" => 0, "output_sha256" => "abc123"}

    assert {:ok, completed, terminal_report} =
             Runners.complete(claimed.id, %{
               "claim_token" => claimed.claim_token,
               "message" => "finished",
               "evidence" => evidence
             })

    assert completed.status == "succeeded"
    assert completed.evidence == evidence
    assert terminal_report.position == 2
    assert terminal_report.event == "completed"

    assert {:ok, replay} = Runners.replay(claimed.id)
    assert replay.assignment.status == "succeeded"
    refute Map.has_key?(replay.assignment, :claim_token)
    assert Enum.map(replay.reports, & &1.position) == [1, 2]
    assert List.last(replay.reports).evidence == evidence

    assert [
             "run.assignment_succeeded",
             "run.assignment_claimed",
             "run.queued",
             "run.command_requested"
           ] =
             "ws-1"
             |> DevIDE.Runs.Ledger.recent_for(10)
             |> Enum.map(& &1.action)
  end

  test "claim token and terminal evidence are required" do
    {:ok, _queued} = Runners.enqueue_command("ws-1", "format")

    {:ok, claimed} =
      Runners.poll(%{
        "runner_id" => "runner-a",
        "capabilities" => ["workspace-command:v1"]
      })

    assert {:error, :claim_token_invalid} =
             Runners.append_report(claimed.id, %{
               "claim_token" => "wrong",
               "event" => "progress",
               "message" => "still running"
             })

    assert {:error, :evidence_required} =
             Runners.complete(claimed.id, %{"claim_token" => claimed.claim_token})
  end

  test "duplicate reports and terminal replay are idempotent by client report id" do
    {:ok, _queued} = Runners.enqueue_command("ws-1", "format")

    {:ok, claimed} =
      Runners.poll(%{
        "runner_id" => "runner-a",
        "capabilities" => ["workspace-command:v1"]
      })

    attrs = %{
      "claim_token" => claimed.claim_token,
      "report_id" => "runner-report-1",
      "event" => "progress",
      "message" => "same message"
    }

    assert {:ok, first} = Runners.append_report(claimed.id, attrs)
    assert {:ok, duplicate} = Runners.append_report(claimed.id, attrs)
    assert first.id == duplicate.id
    assert first.position == duplicate.position

    terminal_attrs = %{
      "claim_token" => claimed.claim_token,
      "report_id" => "runner-terminal-1",
      "message" => "done",
      "evidence" => %{"exit_code" => 0, "output_sha256" => "abc123"}
    }

    assert {:ok, completed, terminal} = Runners.complete(claimed.id, terminal_attrs)

    assert {:ok, duplicate_completed, duplicate_terminal} =
             Runners.complete(claimed.id, terminal_attrs)

    assert completed.id == duplicate_completed.id
    assert terminal.id == duplicate_terminal.id

    assert {:ok, replay_one} = Runners.replay(claimed.id)
    assert {:ok, replay_two} = Runners.replay(claimed.id)
    assert replay_one == replay_two

    assert Enum.map(replay_one.reports, & &1.client_report_id) == [
             "runner-report-1",
             "runner-terminal-1"
           ]

    assert [
             "run.assignment_succeeded",
             "run.assignment_claimed",
             "run.queued",
             "run.command_requested"
           ] =
             "ws-1"
             |> DevIDE.Runs.Ledger.recent_for(10)
             |> Enum.map(& &1.action)
  end

  test "conflicting duplicate reports and duplicate terminals are rejected" do
    {:ok, _queued} = Runners.enqueue_command("ws-1", "format")

    {:ok, claimed} =
      Runners.poll(%{
        "runner_id" => "runner-a",
        "capabilities" => ["workspace-command:v1"]
      })

    attrs = %{
      "claim_token" => claimed.claim_token,
      "report_id" => "runner-report-1",
      "event" => "progress",
      "message" => "first"
    }

    assert {:ok, _first} = Runners.append_report(claimed.id, attrs)

    assert {:error, :duplicate_report_conflict} =
             Runners.append_report(claimed.id, %{attrs | "message" => "different"})

    assert {:ok, _completed, _terminal} =
             Runners.complete(claimed.id, %{
               "claim_token" => claimed.claim_token,
               "report_id" => "terminal-1",
               "message" => "done",
               "evidence" => %{"exit_code" => 0, "output_sha256" => "abc123"}
             })

    assert {:error, :assignment_terminal} =
             Runners.complete(claimed.id, %{
               "claim_token" => claimed.claim_token,
               "report_id" => "terminal-2",
               "message" => "done again",
               "evidence" => %{"exit_code" => 0, "output_sha256" => "abc123"}
             })
  end

  test "lease expiry and stale claim tokens reject reports" do
    {:ok, _queued} = Runners.enqueue_command("ws-1", "compile")

    {:ok, stale_claimed} =
      Runners.poll(%{
        "runner_id" => "runner-stale-token",
        "capabilities" => ["workspace-command:v1"]
      })

    assert {:error, :claim_token_invalid} =
             Runners.append_report(stale_claimed.id, %{
               "claim_token" => "stale-token",
               "event" => "progress",
               "message" => "wrong claimant"
             })

    prev_lease = Application.get_env(:dev_ide, :runner_assignment_lease_ms)
    Application.put_env(:dev_ide, :runner_assignment_lease_ms, -1)

    on_exit(fn ->
      if prev_lease,
        do: Application.put_env(:dev_ide, :runner_assignment_lease_ms, prev_lease),
        else: Application.delete_env(:dev_ide, :runner_assignment_lease_ms)
    end)

    {:ok, _queued} = Runners.enqueue_command("ws-1", "format")

    {:ok, claimed} =
      Runners.poll(%{
        "runner_id" => "runner-a",
        "capabilities" => ["workspace-command:v1"]
      })

    assert {:error, :lease_expired} =
             Runners.append_report(claimed.id, %{
               "claim_token" => claimed.claim_token,
               "event" => "progress",
               "message" => "too late"
             })
  end

  test "each poll claims only one compatible assignment" do
    {:ok, first} = Runners.enqueue_command("ws-1", "compile")
    {:ok, second} = Runners.enqueue_command("ws-1", "test")

    poll = %{
      "runner_id" => "runner-a",
      "capabilities" => ["workspace-command:v1"],
      "workspace_ids" => ["ws-1"]
    }

    {:ok, claimed_one} = Runners.poll(poll)
    {:ok, claimed_two} = Runners.poll(poll)
    assert :none = Runners.poll(poll)

    assert MapSet.new([claimed_one.id, claimed_two.id]) == MapSet.new([first.id, second.id])
    assert claimed_one.claim_token != claimed_two.claim_token
  end

  test "capability routing filters assignments without changing command authorization" do
    {:ok, queued} =
      Runners.enqueue("ws-1", "command:test",
        metadata: %{
          "routing" => %{
            "host" => "host-a",
            "os" => "darwin",
            "tools" => ["mix"],
            "repo" => "onebackend-v3",
            "branch_isolation" => "worktree",
            "runtime_id" => "rt-123",
            "runtime_path" => "/worktrees/rt-123"
          }
        }
      )

    base_poll = %{
      "runner_id" => "runner-a",
      "capabilities" => ["workspace-command:v1", "tool:mix"],
      "workspace_ids" => ["ws-1"],
      "repo" => "onebackend-v3",
      "branch_isolation" => "worktree",
      "runtime_id" => "rt-123",
      "runtime_path" => "/worktrees/rt-123",
      "active_assignments" => 0,
      "concurrency_limit" => 1
    }

    assert :none = Runners.poll(Map.merge(base_poll, %{"host" => "host-b", "os" => "darwin"}))
    assert :none = Runners.poll(Map.merge(base_poll, %{"host" => "host-a", "os" => "linux"}))

    assert :none =
             Runners.poll(
               Map.merge(base_poll, %{
                 "host" => "host-a",
                 "os" => "darwin",
                 "runtime_id" => "rt-other"
               })
             )

    assert :none =
             Runners.poll(
               Map.merge(base_poll, %{
                 "host" => "host-a",
                 "os" => "darwin",
                 "active_assignments" => 1
               })
             )

    assert {:ok, claimed} =
             Runners.poll(Map.merge(base_poll, %{"host" => "host-a", "os" => "darwin"}))

    assert claimed.id == queued.id
    assert claimed.action.argv == ["mix", "test", "--color"]
  end

  test "only approved safe actions can be queued and payloads cannot smuggle execution" do
    assert {:error, :safe_action_not_allowed} = Runners.enqueue_command("ws-1", "deploy")
    assert {:error, :safe_action_not_allowed} = Runners.enqueue("ws-1", "http:proxy")

    assert {:error, :forbidden_payload} =
             Runners.enqueue("ws-1", "command:test",
               metadata: %{"argv" => ["rm", "-rf", "/"], "reason" => "nope"}
             )

    {:ok, _queued} = Runners.enqueue_command("ws-1", "compile")

    {:ok, claimed} =
      Runners.poll(%{
        "runner_id" => "runner-a",
        "capabilities" => ["workspace-command:v1"]
      })

    assert {:error, :forbidden_payload} =
             Runners.append_report(claimed.id, %{
               "claim_token" => claimed.claim_token,
               "event" => "progress",
               "evidence" => %{"url" => "https://example.test/proxy"}
             })
  end

  test "unsafe workspace isolation blocks command assignments" do
    MemoryAdapter.clear()
    seed_workspace("ws-1", :unsafe)

    assert {:error, :unsafe_db} = Runners.enqueue_command("ws-1", "test")

    assert [%{action: "run.command_denied", reason: :unsafe_db}] =
             DevIDE.Runs.Ledger.recent_for("ws-1", 5)
  end

  defp seed_workspace(id, db_isolation) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: "alpha",
        user: "alice",
        branch: "main",
        status: :running,
        path: "/tmp/#{id}",
        metadata: %{"id" => id}
      })

    {:ok, _} =
      State.persist_isolation(id, %DbIsolation{
        isolation: db_isolation,
        source: :env_file,
        summary: Atom.to_string(db_isolation),
        detected_at: DateTime.utc_now()
      })
  end
end
