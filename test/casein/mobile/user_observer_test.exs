defmodule Casein.Mobile.UserObserverTest do
  use Casein.DataCase, async: false

  alias Casein.Audit
  alias Casein.Mobile.{AttentionInbox, UserObserver}
  alias Casein.Runs.Ledger
  alias Casein.Terminals.Session.Info
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

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
        [:casein, :mobile, :user_observer, :start],
        [:casein, :mobile, :card, :upsert],
        [:casein, :mobile, :card, :remove],
        [:casein, :mobile, :snapshot, :broadcast]
      ],
      fn event, measurements, metadata, pid ->
        send(pid, {:mobile_telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _pid} = UserObserver.ensure_started(user_id)

    assert_receive {:mobile_telemetry, [:casein, :mobile, :user_observer, :start], %{count: 1},
                    %{user_id: ^user_id, observer_pid: pid}},
                   1_000

    assert is_pid(pid)

    UserObserver.in_progress_changed(user_id, %{
      workspace_id: "ws-1",
      session_id: "run-1",
      command: "mix test"
    })

    assert_receive {:mobile_telemetry, [:casein, :mobile, :card, :upsert], %{count: 1},
                    %{
                      user_id: ^user_id,
                      card_type: :in_progress,
                      workspace_id: "ws-1",
                      session_id: "run-1",
                      source: "in_progress_changed",
                      operation: :create
                    }},
                   1_000

    assert_receive {:mobile_telemetry, [:casein, :mobile, :snapshot, :broadcast],
                    %{count: 1, duration: duration}, %{user_id: ^user_id, card_count: 1}},
                   1_000

    assert is_integer(duration)

    UserObserver.in_progress_cleared(user_id, %{workspace_id: "ws-1", session_id: "run-1"})

    assert_receive {:mobile_telemetry, [:casein, :mobile, :card, :remove], %{count: 1},
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
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, UserObserver.card_events_topic())

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

  test "live work reconciliation hydrates, dedupes, and removes only its own cards" do
    user_id = unique_user()
    prepare_user(user_id)
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, UserObserver.card_events_topic())

    tab = %Info{
      id: "agent-runtime-1",
      kind: :agent,
      workspace_id: "ws-1",
      runner_id: "runtime-1",
      status: :active,
      metadata: %{
        agent: "codex",
        windows: [%{conversation_title: "Fix visibility", agent_state: :working}]
      }
    }

    first = UserObserver.reconcile_live_work(user_id, "ws-1", [tab])
    assert [live] = first.cards
    assert live.source == "live_work"
    assert live.title == "Fix visibility"
    refute_receive {:mobile_card_created, _card}, 50

    duplicate = UserObserver.reconcile_live_work(user_id, "ws-1", [tab])
    assert duplicate.version == first.version
    assert duplicate.cards == first.cards

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: "ws-1",
      session_id: "review-1",
      review_count: 1
    })

    [{observer_pid, _}] = Registry.lookup(Casein.Mobile.UserObserverRegistry, user_id)
    _ = :sys.get_state(observer_pid)
    cards = UserObserver.snapshot(user_id).cards
    assert Enum.any?(cards, &(&1.type == :needs_review))

    cleared = UserObserver.reconcile_live_work(user_id, "ws-1", [])
    refute Enum.any?(cleared.cards, &(&1.source == "live_work"))
    assert Enum.any?(cleared.cards, &(&1.type == :needs_review))
  end

  test "late directory and hydration messages cannot repopulate a cleared workspace" do
    user_id = unique_user()
    prepare_user(user_id)
    :ok = UserObserver.watch_workspace(user_id, "ws-late")

    [{observer_pid, _}] = Registry.lookup(Casein.Mobile.UserObserverRegistry, user_id)
    state = :sys.get_state(observer_pid)
    hydration_ref = Map.fetch!(state.live_work_hydrations, "ws-late")

    :ok = UserObserver.clear(user_id)

    tab = %Info{
      id: "agent-late",
      kind: :agent,
      workspace_id: "ws-late",
      status: :active,
      metadata: %{agent: "codex", windows: [%{agent_state: :working}]}
    }

    send(observer_pid, {:live_work_hydrated, "ws-late", hydration_ref, [tab]})

    send(
      observer_pid,
      {Casein.Terminals.SessionDirectory, {:sessions_updated, "ws-late", [tab]}}
    )

    _ = :sys.get_state(observer_pid)
    assert UserObserver.snapshot(user_id).cards == []
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

  test "watched audit run lifecycle events produce bounded terminal outcome cards" do
    user_id = unique_user()
    prepare_user(user_id)

    State.sync(%Workspace{id: "ws-1", name: "alpha", user: "dev", path: System.tmp_dir!()})

    :ok = UserObserver.watch_workspace(user_id, "ws-1")
    assert_receive {:mobile_cards_snapshot, %{hydrating_workspaces: []}}, 1_000

    for status <- [:succeeded, :failed, :timed_out] do
      run_id = "run-#{status}"

      Ledger.run_started(%{
        workspace_id: "ws-1",
        actor_id: "agent",
        run_id: run_id,
        command_id: "compile",
        command_line: "mix test"
      })

      assert_receive {:mobile_cards_snapshot, %{cards: cards}}, 1_000
      card = Enum.find(cards, &(&1.session_id == run_id))
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
        command_id: "compile",
        metadata: %{commit_sha: "source-not-merge"}
      })

      assert_receive {:mobile_cards_snapshot, %{cards: cards}}, 1_000
      outcome = Enum.find(cards, &(&1.session_id == run_id))
      assert outcome.type == :outcome
      assert outcome.status == Atom.to_string(status)
      assert outcome.id == card.id
      assert %DateTime{} = outcome.expires_at
      assert Map.get(outcome.meta, :merge_sha) == nil
    end
  end

  test "unrelated and mismatched lifecycle audits are never guessed onto the sole card" do
    user_id = unique_user()
    prepare_user(user_id)
    State.sync(%Workspace{id: "ws-1", name: "alpha", user: "dev", path: System.tmp_dir!()})
    :ok = UserObserver.watch_workspace(user_id, "ws-1")
    assert_receive {:mobile_cards_snapshot, %{hydrating_workspaces: []}}, 1_000

    UserObserver.in_progress_changed(user_id, %{
      workspace_id: "ws-1",
      session_id: "run-1"
    })

    assert_receive {:mobile_cards_snapshot, %{version: version, cards: [_card]}}, 1_000

    Audit.emit!(%{
      workspace_id: "ws-1",
      actor_id: "agent",
      action: "preview.opened",
      target_ref: "run-1"
    })

    refute_receive {:mobile_cards_snapshot, _payload}, 100

    Audit.emit!(%{
      workspace_id: "ws-1",
      actor_id: "agent",
      action: "gate.failed",
      target_type: "git_sha",
      target_ref: "run-1",
      metadata: %{session_id: "run-1"}
    })

    refute_receive {:mobile_cards_snapshot, _payload}, 100
    assert UserObserver.snapshot(user_id).version == version
  end

  test "typed agent blocked event updates the exact tmux card attention projection" do
    previous = Application.get_env(:casein, :mobile_attention_store_enabled)
    Application.put_env(:casein, :mobile_attention_store_enabled, true)
    user_id = unique_user()

    try do
      prepare_user(user_id)
      State.sync(%Workspace{id: "ws-1", name: "alpha", user: "dev", path: System.tmp_dir!()})
      :ok = UserObserver.watch_workspace(user_id, "ws-1")
      assert_receive {:mobile_cards_snapshot, %{hydrating_workspaces: []}}, 1_000

      UserObserver.in_progress_changed(user_id, %{
        workspace_id: "ws-1",
        session_id: "run-1",
        locator: %{tmux_session: "casein_alpha_agent", pane: "%3"}
      })

      assert_receive {:mobile_cards_snapshot, %{cards: [_card]}}, 1_000

      Audit.emit!(%{
        workspace_id: "ws-1",
        actor_id: "agent",
        action: "agent.blocked",
        target_type: "tmux_pane",
        target_ref: "%3",
        metadata: %{
          session: "casein_alpha_agent",
          pane: "%3",
          message: "must not enter attention projection"
        }
      })

      assert_receive {:mobile_cards_snapshot, %{cards: [card]}}, 1_000
      projection = AttentionInbox.project(card)
      assert projection.priority == "critical"
      assert projection.required_decision == "Respond"
      assert projection.lifecycle.status == "waiting"
      refute inspect(card.meta.attention_transition) =~ "must not enter"
    after
      UserObserver.stop(user_id)

      if is_nil(previous) do
        Application.delete_env(:casein, :mobile_attention_store_enabled)
      else
        Application.put_env(:casein, :mobile_attention_store_enabled, previous)
      end
    end
  end

  test "agent lifecycle correlation requires one exact pane and fails closed when ambiguous" do
    previous = Application.get_env(:casein, :mobile_attention_store_enabled)
    Application.put_env(:casein, :mobile_attention_store_enabled, true)
    user_id = unique_user()

    try do
      prepare_user(user_id)
      State.sync(%Workspace{id: "ws-1", name: "alpha", user: "dev", path: System.tmp_dir!()})
      :ok = UserObserver.watch_workspace(user_id, "ws-1")
      assert_receive {:mobile_cards_snapshot, %{hydrating_workspaces: []}}, 1_000

      UserObserver.in_progress_changed(user_id, %{
        workspace_id: "ws-1",
        session_id: "run-1",
        locator: %{tmux_session: "casein_alpha_agent", pane: "%3"}
      })

      UserObserver.in_progress_changed(user_id, %{
        workspace_id: "ws-1",
        session_id: "run-2",
        locator: %{tmux_session: "casein_alpha_agent", pane: "%4"}
      })

      assert_receive {:mobile_cards_snapshot, _payload}, 1_000
      assert_receive {:mobile_cards_snapshot, _payload}, 1_000
      version = UserObserver.snapshot(user_id).version

      Audit.emit!(%{
        workspace_id: "ws-1",
        actor_id: "agent",
        action: "agent.blocked",
        target_type: "tmux_pane",
        target_ref: "%4",
        metadata: %{session: "casein_alpha_agent", pane: "%4"}
      })

      assert_receive {:mobile_cards_snapshot, %{cards: cards}}, 1_000
      blocked = Enum.find(cards, &(&1.session_id == "run-2"))
      working = Enum.find(cards, &(&1.session_id == "run-1"))
      assert AttentionInbox.project(blocked).reason_code == "human_blocked"
      assert AttentionInbox.project(working).reason_code == "working"

      Audit.emit!(%{
        workspace_id: "ws-1",
        actor_id: "agent",
        action: "agent.blocked",
        target_type: "tmux_pane",
        target_ref: nil,
        metadata: %{session: "casein_alpha_agent"}
      })

      refute_receive {:mobile_cards_snapshot, _payload}, 100
      assert UserObserver.snapshot(user_id).version == version + 1
    after
      UserObserver.stop(user_id)

      if is_nil(previous) do
        Application.delete_env(:casein, :mobile_attention_store_enabled)
      else
        Application.put_env(:casein, :mobile_attention_store_enabled, previous)
      end
    end
  end

  test "emits telemetry for observer lifecycle, card changes, and snapshots" do
    user_id = unique_user()
    handler_id = {__MODULE__, self(), :mobile_observer_telemetry}

    :telemetry.attach_many(
      handler_id,
      [
        [:casein, :mobile, :user_observer, :start],
        [:casein, :mobile, :card, :upsert],
        [:casein, :mobile, :card, :remove],
        [:casein, :mobile, :snapshot, :broadcast]
      ],
      fn event, measurements, metadata, pid ->
        send(pid, {:mobile_observer_telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _pid} = UserObserver.ensure_started(user_id)

    assert_receive {:mobile_observer_telemetry, [:casein, :mobile, :user_observer, :start],
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

    assert_receive {:mobile_observer_telemetry, [:casein, :mobile, :card, :upsert], %{count: 1},
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

    assert_receive {:mobile_observer_telemetry, [:casein, :mobile, :snapshot, :broadcast],
                    %{count: 1, duration: duration}, %{user_id: ^user_id, card_count: 1}},
                   1_000

    assert is_integer(duration)

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: "ws-1",
      session_id: "run-1",
      review_count: 0
    })

    assert_receive {:mobile_observer_telemetry, [:casein, :mobile, :card, :remove], %{count: 1},
                    %{
                      user_id: ^user_id,
                      card_type: :needs_review,
                      workspace_id: "ws-1",
                      session_id: "run-1",
                      source: "needs_review_changed"
                    }},
                   1_000
  end

  test "refresh broadcasts the same authoritative version for shared cursor updates" do
    user_id = unique_user()
    prepare_user(user_id)

    UserObserver.in_progress_changed(user_id, %{
      workspace_id: "ws-refresh",
      session_id: "run-refresh"
    })

    assert_receive {:mobile_cards_snapshot, %{version: version, cards: [_card]}}, 1_000
    :ok = UserObserver.refresh(user_id)
    assert_receive {:mobile_cards_snapshot, %{version: ^version, cards: [_card]}}, 1_000
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
