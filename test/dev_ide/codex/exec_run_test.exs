defmodule DevIDE.Codex.ExecRunTest do
  use ExUnit.Case, async: false

  alias DevIDE.Codex.{Event, ExecRun, Store}

  @fixture Path.expand("../../fixtures/codex_exec/fake_codex.sh", __DIR__)

  setup do
    :ok = Store.clear()
    :ok
  end

  test "streams JSONL through the canonical event model and records a run" do
    run_id = "exec-test-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {ExecRun,
         workspace_id: "ws-exec-run",
         root: File.cwd!(),
         prompt: "Review this repository",
         run_id: run_id,
         executable: @fixture,
         timeout_ms: 5_000}
      )

    ref = Process.monitor(pid)
    assert {:ok, %{status: :running, sandbox: :read_only}} = ExecRun.subscribe(pid)

    assert_receive {:codex_exec_event, ^run_id, %Event{type: :thread_started}}
    assert_receive {:codex_exec_event, ^run_id, %Event{type: :turn_started}}

    assert_receive {:codex_exec_event, ^run_id,
                    %Event{type: :item_completed, turn_id: "turn_exec_fake"}}

    assert_receive {:codex_exec_event, ^run_id, %Event{type: :turn_completed}}
    assert_receive {:codex_exec_event, ^run_id, %Event{type: :usage_updated}}
    assert_receive {:codex_exec_exit, ^run_id, 0, :succeeded}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert %{threads: [%{thread_id: "thr_exec_fake", usage: usage}]} =
             Store.workspace_snapshot("ws-exec-run")

    assert usage["total"]["total_tokens"] == 14
  end
end
