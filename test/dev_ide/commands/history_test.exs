defmodule DevIDE.Commands.HistoryTest do
  use ExUnit.Case, async: false

  alias DevIDE.Commands.History
  alias DevIDE.Commands.History.{MemoryAdapter, Record}

  setup do
    MemoryAdapter.clear()
    on_exit(fn -> MemoryAdapter.clear() end)
    :ok
  end

  test "start_run creates a record using allowlisted argv" do
    {:ok, %Record{} = r} =
      History.start_run(%{workspace_id: "w1", actor_id: "alice", command_id: "test"})

    assert r.command_id == "test"
    assert r.argv == ["mix", "test", "--color"]
    assert r.status == "running"
    assert r.workspace_id == "w1"
    assert r.actor_id == "alice"
    assert is_binary(r.id)
    assert %DateTime{} = r.started_at
  end

  test "start_run refuses non-allowlisted command_id" do
    assert {:error, :not_allowed} =
             History.start_run(%{workspace_id: "w", command_id: "rm -rf /"})

    assert {:error, :not_allowed} =
             History.start_run(%{workspace_id: "w", command_id: "compile; pwned"})
  end

  test "argv is fixed by allowlist; payload-controlled argv cannot be injected" do
    # Even if the caller could pass argv, the API ignores it and re-resolves from command_id.
    {:ok, r} =
      History.start_run(%{workspace_id: "w", command_id: "compile", argv: ["evil", "--rm-rf"]})

    assert r.argv == ["mix", "compile"]
  end

  test "finish_run updates status, exit_code, finished_at, duration" do
    {:ok, r} = History.start_run(%{workspace_id: "w", command_id: "format"})

    started = r.started_at
    finished = DateTime.add(started, 250, :millisecond)

    {:ok, updated} =
      History.finish_run(r.id, %{
        status: :succeeded,
        exit_code: 0,
        started_at: started,
        finished_at: finished,
        output: "done\n"
      })

    assert updated.status == "succeeded"
    assert updated.exit_code == "0"
    assert updated.finished_at == finished
    assert updated.duration_ms == 250
    assert updated.output == "done\n"
    refute updated.output_truncated
  end

  test "finish_run timeout sets :timed_out" do
    {:ok, r} = History.start_run(%{workspace_id: "w", command_id: "test"})

    {:ok, updated} =
      History.finish_run(r.id, %{
        status: :timed_out,
        exit_code: :timeout,
        started_at: r.started_at,
        finished_at: DateTime.utc_now(),
        output: "still running…"
      })

    assert updated.status == "timed_out"
    assert updated.exit_code == "timeout"
  end

  test "output is capped and truncated flag is set" do
    {:ok, r} = History.start_run(%{workspace_id: "w", command_id: "test"})
    huge = String.duplicate("x", 80 * 1024)

    {:ok, updated} =
      History.finish_run(r.id, %{
        status: :succeeded,
        exit_code: 0,
        started_at: r.started_at,
        finished_at: DateTime.utc_now(),
        output: huge
      })

    assert updated.output_truncated
    assert updated.output =~ "[…truncated]"
    assert byte_size(updated.output) < byte_size(huge)
  end

  test "recent_for filters by workspace and orders newest-first" do
    {:ok, r1} = History.start_run(%{workspace_id: "a", command_id: "compile"})
    Process.sleep(2)
    {:ok, r2} = History.start_run(%{workspace_id: "a", command_id: "test"})
    {:ok, _} = History.start_run(%{workspace_id: "b", command_id: "format"})

    ids = Enum.map(History.recent_for("a", 10), & &1.id)
    assert ids == [r2.id, r1.id]
    assert History.recent_for("a", 1) |> length() == 1
    assert History.recent_for("b", 10) |> length() == 1
  end

  test "finish_run on unknown id returns :error" do
    assert {:error, :not_found} = History.finish_run("nope", %{status: :succeeded})
  end
end
