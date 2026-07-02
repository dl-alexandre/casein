defmodule DevIDE.Mobile.CardTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.Mobile.Card

  @now ~U[2026-06-27 20:12:00Z]
  @later ~U[2026-06-27 20:13:00Z]

  test "needs_review cards are high priority and dominate actionability" do
    card =
      Card.needs_review(
        %{
          user_id: "dev",
          workspace_id: "ws-1",
          workspace_name: "alpha",
          session_id: "run-1",
          review_count: 4,
          actor_id: "agent-7",
          reason: :policy_review_required,
          source: "run.approval_requested",
          target_ref: "proposal-9",
          last_activity_at: @now,
          agent_reasoning: "The agent wants to edit authentication code.",
          diff_preview: "- old auth\n+ new auth",
          files_changed: ["lib/auth.ex", "test/auth_test.exs"],
          previous_decisions: [%{action: "deny", note: "Missing tests"}]
        },
        @now
      )

    assert card.id == "needs_review:ws-1:run-1"
    assert card.type == :needs_review
    assert card.priority == :high
    assert card.title == "4 items need review"
    assert card.body == "Review required before work continues"
    assert card.action == %{label: "Open", route: {:session_detail, "ws-1", "run-1"}}
    assert card.meta.review_count == 4
    assert card.meta.actor_id == "agent-7"
    assert card.meta.reason == :policy_review_required
    assert card.meta.source == "run.approval_requested"
    assert card.meta.target_ref == "proposal-9"
    assert card.meta.agent_reasoning == "The agent wants to edit authentication code."
    assert card.meta.diff_preview == "- old auth\n+ new auth"
    assert card.meta.files_changed == ["lib/auth.ex", "test/auth_test.exs"]
    assert card.meta.previous_decisions == [%{action: "deny", note: "Missing tests"}]
    assert card.created_at == @now
    assert card.updated_at == @now
  end

  test "needs_review returns nil when the count is cleared" do
    assert Card.needs_review(%{user_id: "dev", workspace_id: "ws-1", review_count: 0}, @now) ==
             nil
  end

  test "in_progress card uses active terminology and normal priority" do
    card =
      Card.in_progress(
        %{
          user_id: "dev",
          workspace_id: "ws-1",
          session_id: "run-1",
          command: "fix auth flow",
          agent_count: 3,
          started_at: @now
        },
        @now
      )

    assert card.type == :in_progress
    assert card.priority == :normal
    assert card.title == "Running: fix auth flow"
    assert card.body == "3 agents active - Started 2026-06-27T20:12:00Z"
    assert card.meta.run_phase == "executing"
    assert card.action == %{label: "View", route: {:session_detail, "ws-1", "run-1"}}
  end

  test "connection_issue keeps one type with reason-specific recovery" do
    offline =
      Card.connection_issue(
        %{user_id: "dev", workspace_id: "ws-1", reason: :offline, last_seen_at: @now},
        @now
      )

    revoked =
      Card.connection_issue(
        %{user_id: "dev", workspace_id: "ws-1", reason: :token_revoked},
        @now
      )

    assert offline.type == :connection_issue
    assert offline.priority == :normal
    assert offline.title == "Workspace offline"
    assert offline.action == %{label: "Retry", route: {:retry_workspace, "ws-1"}}
    assert offline.meta.reason == :offline

    assert revoked.type == :connection_issue
    assert revoked.priority == :high
    assert revoked.title == "Pairing expired"
    assert revoked.action == %{label: "Pair again", route: {:pair_workspace, "ws-1"}}
    assert revoked.meta.reason == :token_revoked
  end

  test "merge_update preserves creation time and advances update time" do
    original = Card.needs_review(%{user_id: "dev", workspace_id: "ws-1", review_count: 1}, @now)

    replacement =
      Card.needs_review(%{user_id: "dev", workspace_id: "ws-1", review_count: 2}, @later)

    merged = Card.merge_update(original, replacement, @later)

    assert merged.created_at == @now
    assert merged.updated_at == @later
    assert merged.title == "2 items need review"
  end

  test "order sorts by priority first then recency" do
    old_high = Card.needs_review(%{user_id: "dev", workspace_id: "ws-1", review_count: 1}, @now)
    new_normal = Card.in_progress(%{user_id: "dev", workspace_id: "ws-2"}, @later)

    assert [^old_high, ^new_normal] = Card.order([new_normal, old_high])

    old_normal = Card.in_progress(%{user_id: "dev", workspace_id: "ws-3"}, @now)

    assert [^new_normal, ^old_normal] = Card.order([old_normal, new_normal])
  end
end
