defmodule Casein.Mobile.CardTest do
  use Casein.TestCase, async: true

  alias Casein.Mobile.Card

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

  describe "normalized contract" do
    test "needs_review carries the normalized card fields" do
      card =
        Card.needs_review(
          %{
            user_id: "dev",
            workspace_id: "ws-1",
            workspace_name: "alpha",
            session_id: "run-1",
            review_count: 2,
            command_id: "cmd-9",
            files_changed: ["lib/auth.ex"],
            diff_preview: "- a\n+ b"
          },
          @now
        )

      assert card.source == "casein"
      assert card.kind == "approval_required"
      assert card.status == "open"
      assert card.resource == %{type: "workspace", id: "ws-1", label: "alpha"}
      assert card.context.session_id == "run-1"
      assert card.context.command_id == "cmd-9"
      assert card.context.files_changed == ["lib/auth.ex"]
      assert card.context.diff_preview == "- a\n+ b"
      assert Card.action_ids(card) == ["approve", "request_changes", "deny"]
    end

    test "context strips nil values" do
      card = Card.needs_review(%{user_id: "dev", workspace_id: "ws-1", review_count: 1}, @now)
      refute Map.has_key?(card.context, :command_id)
      refute Map.has_key?(card.context, :files_changed)
    end

    test "in_progress and connection_issue expose normalized route-only navigation actions" do
      running =
        Card.in_progress(%{user_id: "dev", workspace_id: "ws-1", session_id: "run-1"}, @now)

      assert running.kind == "in_progress"
      assert running.status == "running"
      assert [%{id: "open"} = open] = running.actions
      assert open.route == {:session_detail, "ws-1", "run-1"}
      assert Card.navigation_action?(open)

      offline =
        Card.connection_issue(%{user_id: "dev", workspace_id: "ws-1", reason: :offline}, @now)

      assert offline.kind == "connection_issue"
      assert [%{id: "retry", route: {:retry_workspace, "ws-1"}}] = offline.actions

      revoked =
        Card.connection_issue(
          %{user_id: "dev", workspace_id: "ws-1", reason: :token_revoked},
          @now
        )

      assert [%{id: "pair", route: {:pair_workspace, "ws-1"}}] = revoked.actions
    end

    test "legacy keys remain populated for backward compatibility" do
      card =
        Card.needs_review(
          %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1", review_count: 1},
          @now
        )

      assert card.type == :needs_review
      assert card.action == %{label: "Open", route: {:session_detail, "ws-1", "run-1"}}
      assert card.secondary_actions == []
    end
  end

  describe "workspace_idle proof card" do
    test "builds a low-priority idle card with a route-only resume action" do
      card =
        Card.workspace_idle(
          %{user_id: "dev", workspace_id: "ws-1", workspace_name: "alpha", session_id: "run-9"},
          @now
        )

      assert card.type == :workspace_idle
      assert card.kind == "workspace_idle"
      assert card.status == "idle"
      assert card.priority == :low
      assert card.resource == %{type: "workspace", id: "ws-1", label: "alpha"}
      assert Card.action_ids(card) == ["resume"]

      assert {:ok, spec} = Card.fetch_action(card, "resume")
      assert Card.navigation_action?(spec)
      assert spec.route == {:session_detail, "ws-1", "run-9"}
      assert spec.input == []

      # Legacy navigation action stays populated for back-compat.
      assert card.action == %{label: "Resume", route: {:session_detail, "ws-1", "run-9"}}
    end

    test "returns nil without a session to resume" do
      assert Card.workspace_idle(%{user_id: "dev", workspace_id: "ws-1"}, @now) == nil
    end

    test "review actions are not navigation actions" do
      card = Card.needs_review(%{user_id: "dev", workspace_id: "ws-1", review_count: 1}, @now)
      assert {:ok, approve} = Card.fetch_action(card, "approve")
      refute Card.navigation_action?(approve)
    end
  end

  describe "action specs and validation" do
    setup do
      card = Card.needs_review(%{user_id: "dev", workspace_id: "ws-1", review_count: 1}, @now)
      %{card: card}
    end

    test "fetch_action finds declared actions and rejects others", %{card: card} do
      assert {:ok, %{id: "approve", style: "primary", destructive?: false}} =
               Card.fetch_action(card, "approve")

      assert {:ok, %{id: "deny", destructive?: true}} = Card.fetch_action(card, "deny")
      assert {:error, :unsupported_action} = Card.fetch_action(card, "delete_everything")
    end

    test "approve requires no input", %{card: card} do
      {:ok, spec} = Card.fetch_action(card, "approve")
      assert Card.validate_action_params(spec, %{}) == {:ok, %{}}
      assert Card.validate_action_params(spec, %{"note" => "ignored"}) == {:ok, %{}}
    end

    test "request_changes requires a non-empty note", %{card: card} do
      {:ok, spec} = Card.fetch_action(card, "request_changes")
      assert Card.validate_action_params(spec, %{}) == {:error, {:required, :note}}
      assert Card.validate_action_params(spec, %{"note" => "   "}) == {:error, {:required, :note}}

      assert Card.validate_action_params(spec, %{"note" => " needs tests "}) ==
               {:ok, %{note: "needs tests"}}
    end

    test "note length is enforced", %{card: card} do
      {:ok, spec} = Card.fetch_action(card, "request_changes")

      assert Card.validate_action_params(spec, %{"note" => String.duplicate("x", 281)}) ==
               {:error, {:too_long, :note}}

      assert {:ok, %{note: _}} =
               Card.validate_action_params(spec, %{"note" => String.duplicate("x", 280)})
    end

    test "deny accepts an optional note", %{card: card} do
      {:ok, spec} = Card.fetch_action(card, "deny")
      assert Card.validate_action_params(spec, %{}) == {:ok, %{}}

      assert Card.validate_action_params(spec, %{note: "too risky"}) ==
               {:ok, %{note: "too risky"}}
    end
  end
end
