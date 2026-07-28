defmodule Casein.Mobile.AttentionTest do
  use Casein.DataCase, async: false

  alias Casein.Mobile.{AttentionCursor, AttentionInbox, AttentionTransition, Card}
  alias Casein.Repo

  @now ~U[2026-07-28 09:00:00Z]

  setup do
    previous = Application.get_env(:casein, :mobile_attention_store_enabled)
    Application.put_env(:casein, :mobile_attention_store_enabled, true)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:casein, :mobile_attention_store_enabled)
      else
        Application.put_env(:casein, :mobile_attention_store_enabled, previous)
      end
    end)

    :ok
  end

  test "ranking is deterministic, explainable, and stable across ties" do
    review =
      Card.needs_review(
        %{user_id: "dev", workspace_id: "ws-review", session_id: "run", review_count: 1},
        @now
      )

    failed =
      Card.outcome(
        %{
          user_id: "dev",
          workspace_id: "ws-failed",
          session_id: "run",
          outcome: :failed
        },
        @now
      )

    working =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws-working", session_id: "run"},
        @now
      )

    ordered =
      [working, failed, review]
      |> Enum.map(&{&1, AttentionInbox.project(&1)})
      |> Enum.sort_by(fn {card, attention} -> {-attention.rank, card.id} end)
      |> Enum.map(fn {card, _attention} -> card.id end)

    assert ordered == [review.id, failed.id, working.id]
    assert AttentionInbox.project(review).reason_code == "review_requested"
    assert AttentionInbox.project(review).required_decision == "Review"
    assert AttentionInbox.project(review).notify
    refute AttentionInbox.project(working).notify

    ties =
      for workspace <- ["ws-b", "ws-a"] do
        Card.in_progress(
          %{user_id: "dev", workspace_id: workspace, session_id: "run"},
          @now
        )
      end

    assert ties
           |> Enum.reverse()
           |> Enum.sort_by(fn card ->
             projection = AttentionInbox.project(card)
             {-projection.rank, card.id}
           end)
           |> Enum.map(& &1.workspace_id) == ["ws-a", "ws-b"]
  end

  test "since-viewed exact markers do not swallow a later event" do
    origin_id = "origin-local"

    working =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1"},
        @now
      )

    assert {:ok, first} =
             AttentionInbox.record_card(working, "run.started",
               origin_id: origin_id,
               event_id: "event-start",
               occurred_at: @now
             )

    first_projection = AttentionInbox.project_many("dev", origin_id, [working])[working.id]
    assert first_projection.since_viewed.count == 1
    assert first_projection.since_viewed.through_marker == first.id

    later = DateTime.add(@now, 60, :second)

    failed =
      Card.outcome(
        %{
          user_id: "dev",
          workspace_id: "ws-1",
          session_id: "run-1",
          outcome: :failed
        },
        later
      )

    assert {:ok, second} =
             AttentionInbox.record_card(failed, "run.failed",
               origin_id: origin_id,
               event_id: "event-failed",
               occurred_at: later
             )

    assert {:ok, cursor} =
             AttentionInbox.mark_viewed(
               "dev",
               origin_id,
               AttentionInbox.key(working),
               first.id,
               now: later
             )

    assert cursor.through_transition_id == first.id

    projection = AttentionInbox.project_many("dev", origin_id, [failed])[failed.id]
    assert projection.since_viewed.count == 1
    assert projection.since_viewed.through_marker == second.id
    assert [%{action: "run.failed"}] = projection.since_viewed.changes
  end

  test "multi-device lower marker cannot reset a higher shared cursor" do
    origin_id = "origin-local"

    working =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1"},
        @now
      )

    assert {:ok, first} =
             AttentionInbox.record_card(working, "run.started",
               origin_id: origin_id,
               event_id: "event-1"
             )

    review =
      Card.needs_review(
        %{
          user_id: "dev",
          workspace_id: "ws-1",
          session_id: "run-1",
          review_count: 1
        },
        DateTime.add(@now, 1, :second)
      )

    assert {:ok, second} =
             AttentionInbox.record_card(review, "run.approval_requested",
               origin_id: origin_id,
               event_id: "event-2"
             )

    attention_key = AttentionInbox.key(working)
    assert attention_key == AttentionInbox.key(review)
    assert {:ok, high} = AttentionInbox.mark_viewed("dev", origin_id, attention_key, second.id)
    assert high.through_transition_id == second.id

    assert {:ok, still_high} =
             AttentionInbox.mark_viewed("dev", origin_id, attention_key, first.id)

    assert still_high.through_transition_id == second.id

    assert Repo.get_by!(AttentionCursor,
             user_id: "dev",
             origin_id: origin_id,
             card_id: attention_key
           ).through_transition_id == second.id
  end

  test "forged cross-origin, cross-card, and unknown markers fail closed" do
    card =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1"},
        @now
      )

    assert {:ok, transition} =
             AttentionInbox.record_card(card, "run.started",
               origin_id: "origin-a",
               event_id: "event-1"
             )

    assert {:error, :invalid_attention_marker} =
             AttentionInbox.mark_viewed(
               "dev",
               "origin-b",
               AttentionInbox.key(card),
               transition.id
             )

    assert {:error, :invalid_attention_marker} =
             AttentionInbox.mark_viewed("dev", "origin-a", "other-card", transition.id)

    assert {:error, :invalid_attention_marker} =
             AttentionInbox.mark_viewed(
               "dev",
               "origin-a",
               AttentionInbox.key(card),
               transition.id + 10_000
             )

    refute Repo.get_by(AttentionCursor, user_id: "dev")
  end

  test "duplicate audit event and unchanged semantic update do not add transitions" do
    card =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1"},
        @now
      )

    assert {:ok, %AttentionTransition{}} =
             AttentionInbox.record_card(card, "run.started",
               origin_id: "origin-a",
               event_id: "event-1"
             )

    assert {:ok, :unchanged} =
             AttentionInbox.record_card(card, "run.started",
               origin_id: "origin-a",
               event_id: "event-2"
             )

    assert Repo.aggregate(AttentionTransition, :count) == 1
  end

  test "missing and out-of-order lifecycle events remain explicitly partial" do
    card =
      Card.outcome(
        %{
          user_id: "dev",
          workspace_id: "ws-1",
          session_id: "run-1",
          outcome: :succeeded
        },
        @now
      )

    projection =
      AttentionInbox.project(card, [
        %{
          id: 2,
          event_action: "deploy.succeeded",
          state: "completed",
          phase: "deploying",
          reason_code: "completed",
          occurred_at: @now
        },
        %{
          id: 1,
          event_action: "run.succeeded",
          state: "completed",
          phase: "complete",
          reason_code: "completed",
          occurred_at: @now
        }
      ])

    assert projection.lifecycle.status == "deployed"
    assert projection.lifecycle.partial?
  end

  test "later authoritative retry success supersedes an earlier failure" do
    card =
      Card.outcome(
        %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1", outcome: :succeeded},
        DateTime.add(@now, 30, :second)
      )

    projection =
      AttentionInbox.project(card, [
        %{
          id: 3,
          event_action: "run.succeeded",
          state: "completed",
          phase: "complete",
          reason_code: "completed",
          occurred_at: DateTime.add(@now, 30, :second)
        },
        %{
          id: 1,
          event_action: "run.failed",
          state: "failed",
          phase: "complete",
          reason_code: "failure",
          occurred_at: @now
        },
        %{
          id: 2,
          event_action: "run.started",
          state: "working",
          phase: "executing",
          reason_code: "working",
          occurred_at: DateTime.add(@now, 20, :second)
        }
      ])

    assert projection.lifecycle.status == "completed"

    assert Enum.map(projection.lifecycle.stages, & &1.action) ==
             ["run.failed", "run.started", "run.succeeded"]
  end

  test "latest blocked and check-failure transitions drive attention ranking" do
    card =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1"},
        @now
      )

    blocked =
      AttentionInbox.project(card, [
        %{
          id: 2,
          event_action: "agent.blocked",
          state: "needs_attention",
          phase: "waiting",
          reason_code: "human_blocked",
          occurred_at: DateTime.add(@now, 1, :second)
        },
        %{
          id: 1,
          event_action: "run.started",
          state: "working",
          phase: "executing",
          reason_code: "working",
          occurred_at: @now
        }
      ])

    assert blocked.priority == "critical"
    assert blocked.required_decision == "Respond"
    assert blocked.reason_code == "human_blocked"

    checks_failed =
      AttentionInbox.project(card, [
        %{
          id: 2,
          event_action: "gate.failed",
          state: "failed",
          phase: "testing",
          reason_code: "failure",
          occurred_at: DateTime.add(@now, 1, :second)
        },
        %{
          id: 1,
          event_action: "run.started",
          state: "working",
          phase: "executing",
          reason_code: "working",
          occurred_at: @now
        }
      ])

    assert checks_failed.priority == "high"
    assert checks_failed.required_decision == "Inspect checks"
    assert checks_failed.reason_code == "checks_failed"
  end

  test "active deploy and resolved review remain explicit lifecycle states" do
    card =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1"},
        @now
      )

    deploying =
      AttentionInbox.project(card, [
        %{
          id: 2,
          event_action: "deploy.started",
          state: "working",
          phase: "deploying",
          reason_code: "deploy_started",
          occurred_at: DateTime.add(@now, 1, :second)
        },
        %{
          id: 1,
          event_action: "run.succeeded",
          state: "completed",
          phase: "complete",
          reason_code: "completed",
          occurred_at: @now
        }
      ])

    assert deploying.lifecycle.status == "deploying"

    resolved =
      AttentionInbox.project(card, [
        %{
          id: 2,
          event_action: "run.approval_granted",
          state: "working",
          phase: "executing",
          reason_code: "review_approved",
          occurred_at: DateTime.add(@now, 1, :second)
        },
        %{
          id: 1,
          event_action: "run.approval_requested",
          state: "needs_attention",
          phase: "review",
          reason_code: "review_requested",
          occurred_at: @now
        }
      ])

    assert resolved.lifecycle.status == "review_resolved"
  end

  test "completion reports only authoritative bounded outcome facts" do
    working =
      Card.in_progress(
        %{
          user_id: "dev",
          workspace_id: "ws-1",
          session_id: "run-1",
          command_id: "task-1"
        },
        @now
      )

    refute AttentionInbox.project(working).completion.authoritative?
    assert AttentionInbox.project(working).completion.outcome == nil

    outcome =
      Card.outcome(
        %{
          user_id: "dev",
          workspace_id: "ws-1",
          session_id: "run-1",
          command_id: "task-1",
          outcome: :succeeded,
          verification: "gate passed",
          merge_sha: String.duplicate("a", 40),
          deploy_sha: String.duplicate("b", 40)
        },
        @now
      )

    projection = AttentionInbox.project(outcome)
    assert projection.key == AttentionInbox.key(working)
    assert projection.completion.authoritative?
    assert projection.completion.outcome == "completed"
    assert projection.completion.verification == "gate passed"
    assert projection.completion.merge_sha == String.duplicate("a", 40)
    assert projection.completion.deploy_sha == String.duplicate("b", 40)
  end

  test "transition history is bounded per origin-qualified card" do
    card =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1"},
        @now
      )

    for number <- 1..55 do
      action = if rem(number, 2) == 0, do: "run.started", else: "agent.state_changed"

      assert {:ok, %AttentionTransition{}} =
               AttentionInbox.record_card(card, action,
                 origin_id: "origin-a",
                 event_id: "event-#{number}",
                 occurred_at: DateTime.add(@now, number, :second)
               )
    end

    assert Repo.aggregate(AttentionTransition, :count) == 50

    projection = AttentionInbox.project_many("dev", "origin-a", [card])[card.id]
    assert projection.since_viewed.count == 50
    assert projection.since_viewed.truncated?
    assert length(projection.since_viewed.changes) == 5
  end

  test "late old events cannot displace the latest lifecycle fact from the bounded fold" do
    card =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1"},
        @now
      )

    assert {:ok, %AttentionTransition{}} =
             AttentionInbox.record_card(card, "agent.blocked",
               origin_id: "origin-a",
               event_id: "latest-blocker",
               occurred_at: DateTime.add(@now, 100, :second)
             )

    for number <- 1..14 do
      action = if rem(number, 2) == 0, do: "run.started", else: "agent.state_changed"

      assert {:ok, %AttentionTransition{}} =
               AttentionInbox.record_card(card, action,
                 origin_id: "origin-a",
                 event_id: "late-old-#{number}",
                 occurred_at: DateTime.add(@now, number, :second)
               )
    end

    projection = AttentionInbox.project_many("dev", "origin-a", [card])[card.id]

    assert projection.reason_code == "human_blocked"
    assert projection.required_decision == "Respond"
    assert DateTime.compare(projection.changed_at, DateTime.add(@now, 100, :second)) == :eq
    assert projection.since_viewed.through_marker > 1
  end

  test "audited lifecycle actions map to explicit event semantics" do
    card =
      Card.outcome(
        %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1", outcome: :succeeded},
        @now
      )

    assert AttentionInbox.lifecycle_action?("deploy.started")
    refute AttentionInbox.lifecycle_action?("preview.opened")

    assert {:ok, transition} =
             AttentionInbox.record_card(card, "deploy.started",
               origin_id: "origin-a",
               event_id: "deploy-1"
             )

    assert transition.state == "working"
    assert transition.phase == "deploying"
    assert transition.reason_code == "deploy_started"
  end
end
