defmodule DevIDE.Mobile.UserObserverTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Audit
  alias DevIDE.Mobile.UserObserver
  alias DevIDE.Runs.Ledger
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    Audit.clear()
    MemoryAdapter.clear()

    on_exit(fn ->
      Audit.clear()
      MemoryAdapter.clear()
    end)

    :ok
  end

  test "ensure_started is idempotent per user" do
    user_id = unique_user()

    assert {:ok, pid} = UserObserver.ensure_started(user_id)
    assert {:ok, ^pid} = UserObserver.ensure_started(user_id)
  end

  test "emits telemetry for observer lifecycle card operations and broadcasts" do
    user_id = unique_user()
    handler_id = {__MODULE__, self(), :mobile_telemetry}

    :telemetry.attach_many(
      handler_id,
      [
        [:dev_ide, :mobile, :user_observer, :start],
        [:dev_ide, :mobile, :card, :upsert],
        [:dev_ide, :mobile, :card, :remove],
        [:dev_ide, :mobile, :snapshot, :broadcast]
      ],
      fn event, measurements, metadata, pid ->
        send(pid, {:mobile_telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _pid} = UserObserver.ensure_started(user_id)

    assert_receive {:mobile_telemetry, [:dev_ide, :mobile, :user_observer, :start], %{count: 1},
                    %{user_id: ^user_id, observer_pid: pid}},
                   1_000

    assert is_pid(pid)

    UserObserver.in_progress_changed(user_id, %{
      workspace_id: "ws-1",
      session_id: "run-1",
      command: "mix test"
    })

    assert_receive {:mobile_telemetry, [:dev_ide, :mobile, :card, :upsert], %{count: 1},
                    %{
                      user_id: ^user_id,
                      card_type: :in_progress,
                      workspace_id: "ws-1",
                      session_id: "run-1",
                      source: "in_progress_changed",
                      operation: :create
                    }},
                   1_000

    assert_receive {:mobile_telemetry, [:dev_ide, :mobile, :snapshot, :broadcast],
                    %{count: 1, duration: duration}, %{user_id: ^user_id, card_count: 1}},
                   1_000

    assert is_integer(duration)

    UserObserver.in_progress_cleared(user_id, %{workspace_id: "ws-1", session_id: "run-1"})

    assert_receive {:mobile_telemetry, [:dev_ide, :mobile, :card, :remove], %{count: 1},
                    %{
                      user_id: ^user_id,
                      card_type: :in_progress,
                      workspace_id: "ws-1",
                      session_id: "run-1",
                      source: "in_progress_cleared"
                    }},
                   1_000
  end

  test "needs_review updates dedupe by user workspace session and type" do
    user_id = unique_user()
    prepare_user(user_id)
    :ok = Phoenix.PubSub.subscribe(DevIde.PubSub, UserObserver.card_events_topic())

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: "ws-1",
      workspace_name: "alpha",
      session_id: "run-1",
      review_count: 1
    })

    assert_receive {:mobile_cards_snapshot, %{version: first_version, cards: [first]}}, 1_000
    assert first.id == "needs_review:ws-1:run-1"
    assert first.title == "1 item needs review"
    assert first.priority == :high
    assert_receive {:mobile_card_created, %{id: "needs_review:ws-1:run-1"}}, 1_000

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: "ws-1",
      workspace_name: "alpha",
      session_id: "run-1",
      review_count: 3
    })

    assert_receive {:mobile_cards_snapshot, %{version: updated_version, cards: [updated]}}, 1_000
    assert updated_version > first_version
    assert updated.id == first.id
    assert updated.title == "3 items need review"
    assert updated.created_at == first.created_at
    assert DateTime.compare(updated.updated_at, first.updated_at) in [:gt, :eq]
    refute_receive {:mobile_card_created, %{id: "needs_review:ws-1:run-1"}}, 100

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: "ws-1",
      session_id: "run-1",
      review_count: 0
    })

    assert_receive {:mobile_cards_snapshot, %{version: cleared_version, cards: []}}, 1_000
    assert cleared_version > updated_version
  end

  test "in_progress and connection_issue cards can be cleared independently" do
    user_id = unique_user()
    prepare_user(user_id)

    UserObserver.in_progress_changed(user_id, %{
      workspace_id: "ws-1",
      session_id: "run-1",
      command: "mix test"
    })

    assert_receive {:mobile_cards_snapshot, %{cards: [active]}}, 1_000
    assert active.type == :in_progress

    UserObserver.connection_issue_changed(user_id, %{
      workspace_id: "ws-1",
      reason: :offline
    })

    assert_receive {:mobile_cards_snapshot, %{cards: cards}}, 1_000
    assert Enum.map(cards, & &1.type) == [:connection_issue, :in_progress]

    UserObserver.connection_live(user_id, "ws-1")

    assert_receive {:mobile_cards_snapshot, %{cards: [remaining]}}, 1_000
    assert remaining.type == :in_progress

    UserObserver.in_progress_cleared(user_id, %{workspace_id: "ws-1", session_id: "run-1"})

    assert_receive {:mobile_cards_snapshot, %{cards: []}}, 1_000
  end

  test "watched audit approval events produce needs_review cards" do
    user_id = unique_user()
    prepare_user(user_id)

    State.sync(%Workspace{id: "ws-1", name: "alpha", user: "dev", path: System.tmp_dir!()})

    :ok = UserObserver.watch_workspace(user_id, "ws-1")

    Ledger.approval_requested(%{
      workspace_id: "ws-1",
      actor_id: "agent",
      run_id: "run-1",
      command_id: "compile",
      metadata: %{
        review_count: 2,
        agent_reasoning: "Agent is changing auth checks.",
        diff_preview: "- allow all\n+ require role",
        files_changed: ["lib/auth.ex"],
        previous_decisions: [%{"action" => "request_changes", "note" => "Explain risk"}]
      }
    })

    assert_receive {:mobile_cards_snapshot, %{cards: [card]}}, 1_000
    assert card.type == :needs_review
    assert card.workspace_name == "alpha"
    assert card.session_id == "run-1"
    assert card.title == "2 items need review"
    assert card.meta.actor_id == "agent"
    assert card.meta.source == "run.approval_requested"
    assert card.meta.agent_reasoning == "Agent is changing auth checks."
    assert card.meta.diff_preview == "- allow all\n+ require role"
    assert card.meta.files_changed == ["lib/auth.ex"]

    assert card.meta.previous_decisions == [
             %{"action" => "request_changes", "note" => "Explain risk"}
           ]

    Ledger.approval_granted(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      run_id: "run-1",
      command_id: "compile"
    })

    assert_receive {:mobile_cards_snapshot, %{cards: []}}, 1_000
  end

  test "watched audit run lifecycle events produce and clear in_progress cards" do
    user_id = unique_user()
    prepare_user(user_id)

    State.sync(%Workspace{id: "ws-1", name: "alpha", user: "dev", path: System.tmp_dir!()})

    :ok = UserObserver.watch_workspace(user_id, "ws-1")

    for status <- [:succeeded, :failed, :timed_out] do
      run_id = "run-#{status}"

      Ledger.run_started(%{
        workspace_id: "ws-1",
        actor_id: "agent",
        run_id: run_id,
        command_id: "compile",
        command_line: "mix test"
      })

      assert_receive {:mobile_cards_snapshot, %{cards: [card]}}, 1_000
      assert card.type == :in_progress
      assert card.workspace_id == "ws-1"
      assert card.workspace_name == "alpha"
      assert card.session_id == run_id
      assert card.title == "Running: mix test"
      assert card.meta.run_phase == "executing"

      Ledger.run_finished(status, %{
        workspace_id: "ws-1",
        actor_id: "agent",
        run_id: run_id,
        command_id: "compile"
      })

      assert_receive {:mobile_cards_snapshot, %{cards: []}}, 1_000
    end
  end

  test "emits telemetry for observer lifecycle, card changes, and snapshots" do
    user_id = unique_user()
    handler_id = {__MODULE__, self(), :mobile_observer_telemetry}

    :telemetry.attach_many(
      handler_id,
      [
        [:dev_ide, :mobile, :user_observer, :start],
        [:dev_ide, :mobile, :card, :upsert],
        [:dev_ide, :mobile, :card, :remove],
        [:dev_ide, :mobile, :snapshot, :broadcast]
      ],
      fn event, measurements, metadata, pid ->
        send(pid, {:mobile_observer_telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _pid} = UserObserver.ensure_started(user_id)

    assert_receive {:mobile_observer_telemetry, [:dev_ide, :mobile, :user_observer, :start],
                    %{count: 1}, %{user_id: ^user_id, observer_pid: observer_pid}},
                   1_000

    assert is_pid(observer_pid)

    :ok = UserObserver.subscribe(user_id)

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: "ws-1",
      workspace_name: "alpha",
      session_id: "run-1",
      review_count: 1
    })

    assert_receive {:mobile_observer_telemetry, [:dev_ide, :mobile, :card, :upsert], %{count: 1},
                    %{
                      user_id: ^user_id,
                      card_type: :needs_review,
                      workspace_id: "ws-1",
                      session_id: "run-1",
                      source: "needs_review_changed",
                      operation: :create
                    }},
                   1_000

    assert_receive {:mobile_cards_snapshot, %{cards: [_card]}}, 1_000

    assert_receive {:mobile_observer_telemetry, [:dev_ide, :mobile, :snapshot, :broadcast],
                    %{count: 1, duration: duration}, %{user_id: ^user_id, card_count: 1}},
                   1_000

    assert is_integer(duration)

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: "ws-1",
      session_id: "run-1",
      review_count: 0
    })

    assert_receive {:mobile_observer_telemetry, [:dev_ide, :mobile, :card, :remove], %{count: 1},
                    %{
                      user_id: ^user_id,
                      card_type: :needs_review,
                      workspace_id: "ws-1",
                      session_id: "run-1",
                      source: "needs_review_changed"
                    }},
                   1_000
  end

  defp prepare_user(user_id) do
    {:ok, _pid} = UserObserver.ensure_started(user_id)
    :ok = UserObserver.clear(user_id)
    :ok = UserObserver.subscribe(user_id)
    flush()
  end

  defp unique_user do
    user_id = "observer-#{System.unique_integer([:positive])}"
    on_exit(fn -> UserObserver.stop(user_id) end)
    user_id
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
