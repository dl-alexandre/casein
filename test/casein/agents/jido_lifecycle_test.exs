defmodule Casein.Agents.JidoLifecycleTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.{Activity, AgentEvents, Inbox, JidoActions, JidoLifecycle, JidoPod}
  alias Casein.Agents.Inbox.Address
  alias Casein.Agents.JidoLifecycle.{Envelope, ReadModel}
  alias Casein.Terminals.AgentState
  alias Casein.Test.Eventually

  @workspace "ws-jido-lifecycle"

  setup do
    previous = %{
      flag: Application.get_env(:casein, :jido_headless),
      workspaces: Application.get_env(:casein, :jido_headless_workspaces),
      runner: Application.get_env(:casein, :jido_code_actions)
    }

    Application.put_env(:casein, :jido_headless, true)
    Application.put_env(:casein, :jido_headless_workspaces, %{})
    Application.put_env(:casein, :jido_code_actions, fn _name, args, _ctx -> {:ok, args} end)
    AgentEvents.clear()
    Activity.clear()
    AgentState.clear()

    on_exit(fn ->
      Registry.select(Casein.Agents.JidoPod.Registry, [
        {{{:pod, :"$1"}, :_, :_}, [], [:"$1"]}
      ])
      |> Enum.each(&JidoPod.stop_pod/1)

      AgentEvents.clear()
      Activity.clear()
      AgentState.clear()
      restore(:jido_headless, previous.flag)
      restore(:jido_headless_workspaces, previous.workspaces)
      restore(:jido_code_actions, previous.runner)
    end)

    :ok
  end

  test "envelope drops secrets and caps payload before persist" do
    envelope =
      Envelope.build(%{
        workspace_id: @workspace,
        attempt_id: "att-1",
        action: "code_exec",
        sequence: 1,
        event_type: "jido.action",
        payload: %{
          "token" => "super-secret",
          "command" => "cat /etc/shadow",
          "summary" => "ran format",
          "blob" => String.duplicate("x", 20_000)
        }
      })

    refute inspect(envelope.payload) =~ "super-secret"
    refute inspect(envelope.payload) =~ "/etc/shadow"
    assert envelope.payload["summary"] == "ran format"
    assert envelope.workspace_id == @workspace
    assert envelope.attempt_id == "att-1"
    assert envelope.correlation_id == "att-1"
    assert is_integer(envelope.sequence)
    assert %DateTime{} = envelope.timestamp
  end

  test "replay reconstructs lifecycle, progress, checkpoint, and result" do
    attempt_id = "att-replay"

    JidoLifecycle.ingest_attempt(%{
      workspace_id: @workspace,
      attempt_id: attempt_id,
      task_id: "task-1",
      worktree_path: "/tmp/jido-lifecycle",
      state: :running,
      next_index: 0,
      completed_count: 0
    })

    JidoLifecycle.ingest_action(
      "report_progress",
      %{summary: "patched note.txt"},
      %{workspace_id: @workspace, attempt_id: attempt_id, task_id: "task-1"}
    )

    JidoLifecycle.ingest_attempt(%{
      workspace_id: @workspace,
      attempt_id: attempt_id,
      task_id: "task-1",
      worktree_path: "/tmp/jido-lifecycle",
      state: :running,
      next_index: 1,
      completed_count: 1
    })

    JidoLifecycle.ingest_action(
      "report_result",
      %{status: "done", summary: "I am complete"},
      %{workspace_id: @workspace, attempt_id: attempt_id, task_id: "task-1"}
    )

    first = JidoLifecycle.replay(@workspace, attempt_id)
    second = JidoLifecycle.replay(@workspace, attempt_id)

    assert first == second
    assert first.state == :running
    assert first.last_progress.summary == "patched note.txt"
    assert first.checkpoint.next_index == 1
    assert first.result.status == "done"
    assert first.result.complete? == false
    assert first.headless == true
    refute first.pane_id
  end

  test "a completion sentence and missing pane do not invent completed or idle" do
    attempt_id = "att-honest"

    JidoLifecycle.ingest_attempt(%{
      workspace_id: @workspace,
      attempt_id: attempt_id,
      task_id: "task-honest",
      state: :running
    })

    JidoLifecycle.ingest_action(
      "report_result",
      %{status: "completed", summary: "All done!"},
      %{workspace_id: @workspace, attempt_id: attempt_id}
    )

    snapshot = JidoLifecycle.replay(@workspace, attempt_id)
    assert snapshot.state == :running
    refute snapshot.state in [:completed, :idle]
    assert snapshot.result.complete? == false
  end

  test "deduplicates reconnect replay of the same source event" do
    attrs = %{
      workspace_id: @workspace,
      attempt_id: "att-dedupe",
      task_id: "task-dedupe",
      state: :queued,
      next_index: 0,
      completed_count: 0
    }

    assert :ok = JidoLifecycle.ingest_attempt(attrs)
    assert :ok = JidoLifecycle.ingest_attempt(attrs)

    events = AgentEvents.list_for_session(@workspace, "att-dedupe", limit: 50)
    lifecycle = Enum.filter(events, &(&1.event_type == "jido.lifecycle"))
    assert length(lifecycle) == 1
  end

  test "cancellation and timeout persist as terminal outcomes" do
    JidoLifecycle.ingest_attempt(%{
      workspace_id: @workspace,
      attempt_id: "att-cancel",
      state: :running
    })

    JidoLifecycle.ingest_attempt(%{
      workspace_id: @workspace,
      attempt_id: "att-cancel",
      state: :cancelled,
      reason: :cancelled
    })

    JidoLifecycle.ingest_attempt(%{
      workspace_id: @workspace,
      attempt_id: "att-timeout",
      state: :running
    })

    JidoLifecycle.ingest_attempt(%{
      workspace_id: @workspace,
      attempt_id: "att-timeout",
      state: :timed_out,
      error: :deadline
    })

    assert {:ok, %{state: :cancelled}} = JidoLifecycle.get(@workspace, "att-cancel")

    assert {:ok, %{state: :timed_out, retryable?: true}} =
             JidoLifecycle.get(@workspace, "att-timeout")
  end

  test "provider failure is retryable and evidence becomes stale after progress" do
    ctx = %{workspace_id: @workspace, attempt_id: "att-err", worktree_path: "/tmp/jido-ev"}

    JidoLifecycle.ingest_attempt(%{
      workspace_id: @workspace,
      attempt_id: "att-err",
      state: :running,
      worktree_path: "/tmp/jido-ev"
    })

    JidoLifecycle.ingest_action(
      "handoff_evidence",
      %{paths: ["lib/a.ex"], verification_ref: "format"},
      ctx
    )

    assert {:ok, %{evidence: %{freshness: :current}}} = JidoLifecycle.get(@workspace, "att-err")

    JidoLifecycle.ingest_action("report_progress", %{summary: "more work"}, ctx)
    assert {:ok, %{evidence: %{freshness: :stale}}} = JidoLifecycle.get(@workspace, "att-err")

    JidoLifecycle.ingest_action(
      "code_read",
      %{result: :provider_failure, error: :provider_unavailable, retryable: true},
      ctx
    )

    assert {:ok, %{retryable?: true}} = JidoLifecycle.get(@workspace, "att-err")
  end

  test "human answer resumes the same attempt and workers cannot self-approve" do
    Application.put_env(:casein, :jido_code_actions, fn _name, _args, _ctx ->
      {:ok, %{awaiting_human: true, request_id: "need-1"}}
    end)

    {:ok, attempt} =
      JidoPod.admit(%{
        workspace_id: @workspace,
        runtime: :jido,
        task_id: "task-human",
        worktree_path: "/tmp/jido-human",
        actions: [%{name: "code_read", args: %{path: "README.md"}}]
      })

    assert {:ok, parked} =
             Eventually.await(
               fn ->
                 case JidoPod.status(@workspace, attempt.attempt_id) do
                   {:ok, %{state: :awaiting_human} = parked} -> {:ok, parked}
                   _ -> false
                 end
               end,
               timeout_ms: 2_000,
               message: "attempt did not park for human"
             )

    JidoLifecycle.ingest_action(
      "request_human_input",
      %{request_id: "need-1", kind: "clarification", prompt: "Which module?"},
      %{
        workspace_id: @workspace,
        attempt_id: parked.attempt_id,
        task_id: parked.task_id,
        worktree_path: "/tmp/jido-human"
      }
    )

    assert {:error, :human_required} =
             JidoLifecycle.answer(@workspace, %{
               attempt_id: parked.attempt_id,
               actor_kind: :worker,
               request_id: "need-1"
             })

    assert {:ok, %{snapshot: snapshot, resume: resume}} =
             JidoLifecycle.answer(@workspace, %{
               attempt_id: parked.attempt_id,
               actor_kind: :human,
               actor_id: "operator",
               request_id: "need-1"
             })

    assert snapshot.blocker == nil
    assert snapshot.resume_token == JidoLifecycle.resume_token(@workspace, parked.attempt_id)
    assert match?({:ok, _}, resume)

    inbox = Inbox.list(@workspace, Address.for_worktree("/tmp/jido-human"))
    assert Enum.any?(inbox, &(&1.message_id == "need-1"))
  end

  test "OpenCode pane reports project through the same read model" do
    AgentState.report(@workspace, "casein_ws_demo", "%9", :working, "implementing",
      agent_session_id: "oc-sess-1"
    )

    _ = :sys.get_state(Casein.Terminals.AgentState)

    assert {:ok, snapshot} =
             Eventually.await(
               fn ->
                 case JidoLifecycle.get(@workspace, "oc-sess-1") do
                   {:ok, %{state: :running} = snap} -> {:ok, snap}
                   _ -> false
                 end
               end,
               timeout_ms: 1_000,
               message: "opencode snapshot missing"
             )

    assert snapshot.runtime == :opencode
    assert snapshot.headless == false
    assert snapshot.state == :running
    refute snapshot.state == :completed
    assert Enum.any?(JidoLifecycle.list(@workspace), &(&1.worker_id == "oc-sess-1"))

    assert [transition] =
             AgentEvents.list_for_session(@workspace, "oc-sess-1", limit: 10)

    assert transition.event_type == "agent.state_changed"
    assert transition.payload["message_present"] == true
  end

  test "pod transitions appear on the cockpit list with identity" do
    {:ok, attempt} =
      JidoPod.admit(%{
        workspace_id: @workspace,
        runtime: :jido,
        task_id: "task-list",
        worktree_path: "/tmp/jido-list",
        actions: []
      })

    assert {:ok, %{state: :completed}} = JidoPod.await(@workspace, attempt.attempt_id)

    assert {:ok, snapshot} =
             Eventually.await(
               fn ->
                 case JidoLifecycle.get(@workspace, attempt.attempt_id) do
                   {:ok, %{state: :completed} = snap} -> {:ok, snap}
                   _ -> false
                 end
               end,
               timeout_ms: 1_000,
               message: "completed snapshot missing"
             )

    assert snapshot.task_id == "task-list"
    assert snapshot.worktree_path == "/tmp/jido-list"
    assert snapshot.headless == true
    assert snapshot.resume_token == JidoLifecycle.resume_token(@workspace, attempt.attempt_id)
    assert Enum.any?(Activity.recent(@workspace, 30), &(&1.source == :jido_lifecycle))
  end

  test "typed action human block projects a resume token" do
    assert {:error, %{result: :blocked_on_human}} =
             JidoActions.invoke(
               "request_clarification",
               %{request_id: "q-22", question: "Ship it?"},
               %{
                 workspace_id: @workspace,
                 task_id: "task-q",
                 attempt_id: "att-q",
                 worktree_path: "/tmp/jido-q"
               }
             )

    assert {:ok, snapshot} = JidoLifecycle.get(@workspace, "att-q")
    assert snapshot.state == :awaiting_human
    assert snapshot.blocker.request_id == "q-22"
    assert snapshot.blocker.resume_token == JidoLifecycle.resume_token(@workspace, "att-q")
    assert snapshot.blocker.prompt_present == true
  end

  test "folding events out of order still yields one terminal outcome" do
    now = DateTime.utc_now()

    events = [
      event("jido.lifecycle", 2, now, %{"state" => "completed", "attempt_id" => "att-ord"}),
      event("jido.lifecycle", 1, DateTime.add(now, -2, :second), %{
        "state" => "running",
        "attempt_id" => "att-ord"
      }),
      event("jido.progress", 1, DateTime.add(now, -1, :second), %{
        "summary" => "halfway",
        "attempt_id" => "att-ord"
      })
    ]

    snapshot = ReadModel.fold(events)
    assert snapshot.state == :completed
    assert snapshot.last_progress.summary == "halfway"
  end

  defp event(type, sequence, at, payload) do
    %{
      id: Ecto.UUID.generate(),
      event_type: type,
      source_sequence: sequence,
      sequence: sequence,
      occurred_at: at,
      workspace_id: @workspace,
      agent_session_id: payload["attempt_id"],
      payload: payload,
      status: payload["state"]
    }
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
