defmodule CaseinMob.ReviewDecisionScreenTest do
  use Mob.ScreenCase, async: false

  alias CaseinMob.ReviewDecisionScreen

  test "renders review context and decision actions" do
    view = mount_screen(ReviewDecisionScreen, %{card: review_card()})

    assert_renderable(view)
    assert text(view) =~ "Review request"
    assert text(view) =~ "4 items need review"
    assert text(view) =~ "Review required before work continues"
    assert text(view) =~ "Context"
    assert text(view) =~ "Workspace"
    assert text(view) =~ "Mobile Workspace"
    assert text(view) =~ "Run/session"
    assert text(view) =~ "run-1"
    assert text(view) =~ "Command"
    assert text(view) =~ "mix test"
    assert text(view) =~ "Review count"
    assert text(view) =~ "4"
    assert text(view) =~ "Requested by"
    assert text(view) =~ "agent-7"
    assert text(view) =~ "Reason"
    assert text(view) =~ "policy_review_required"
    assert text(view) =~ "Source"
    assert text(view) =~ "run.approval_requested"
    assert text(view) =~ "Target"
    assert text(view) =~ "proposal-9"
    assert text(view) =~ "Last activity"
    assert text(view) =~ "2026-06-27T20:12:00Z"
    assert text(view) =~ "Approval"
    assert text(view) =~ "approval-1"
    assert text(view) =~ "Decision context"
    assert text(view) =~ "Why this needs review"
    assert text(view) =~ "Agent wants to update the auth gate before continuing."
    assert text(view) =~ "Evidence handoff"
    assert text(view) =~ "Bounded diff excerpt"
    assert text(view) =~ "+ require role"
    assert text(view) =~ "Changed files"
    assert text(view) =~ "lib/auth.ex"
    assert text(view) =~ "test/auth_test.exs"
    assert text(view) =~ "Local Mac · live · 2026-07-24T12:00:00Z"
    assert find(view, :button, text: "Open full diff in PWA")
    assert text(view) =~ "Recent decisions"
    assert text(view) =~ "Needs narrower scope"
    assert find(view, :button, text: "Approve")
    assert find(view, :button, text: "Deny")
    assert find(view, :button, text: "Request changes")
    assert find(view, :button, text: "Back").props.fill_width == false
  end

  test "approve submits immediately while destructive deny requires explicit confirmation" do
    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
      |> authoritative_refresh(review_card())
      |> render_info({:tap, {:action, "approve"}})

    assert assigns(view).submitted_action == "approve"
    assert text(view) =~ "Approve sent"

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
      |> authoritative_refresh(review_card())
      |> render_info({:tap, {:action, "deny"}})

    assert assigns(view).submitted_action == nil
    assert text(view) =~ "Deny this run?"
    assert find(view, :button, text: "Confirm Deny")
    assert find(view, :button, text: "Cancel")

    view = render_info(view, {:tap, {:confirm_action, "deny"}})
    assert assigns(view).submitted_action == "deny"
    assert text(view) =~ "Deny sent"
  end

  test "destructive confirmation can be cancelled without dispatch" do
    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
      |> authoritative_refresh(review_card())
      |> render_info({:tap, {:action, "deny"}})
      |> render_info({:tap, :cancel_confirmation})

    assert assigns(view).submitted_action == nil
    assert assigns(view).pending_confirmation == nil
    assert text(view) =~ "Action cancelled"
    assert find(view, :button, text: "Deny")
  end

  test "disconnect disables actions until an authoritative snapshot refreshes the card" do
    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
      |> render_info({:mobile_cards_status, {:disconnected, :network_unavailable}})

    assert assigns(view).authoritative? == false
    assert find(view, :button, text: "Approve").props.disabled == true
    assert text(view) =~ "Connection lost"

    view = render_info(view, {:tap, {:action, "approve"}})
    assert assigns(view).submitted_action == nil
    assert text(view) =~ "Reconnect and refresh"

    view =
      view
      |> render_info({:mobile_cards_snapshot, %{"cards" => [review_card()]}})

    assert assigns(view).authoritative? == false
    assert find(view, :button, text: "Approve").props.disabled == true

    view =
      view
      |> render_info({:mobile_cards_status, :joined})

    assert assigns(view).authoritative? == true
    assert find(view, :button, text: "Approve").props.disabled == false
  end

  test "request changes requires and trims a short note" do
    initial =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
      |> authoritative_refresh(review_card())

    assert find(initial, :button, text: "Request changes").props.disabled == false
    refute find(initial, :text_field)

    view = render_info(initial, {:tap, {:action, "request_changes"}})

    assert text(view) =~ "Add a short note first"
    assert assigns(view).submitted_action == nil
    assert find(view, :text_field).props.test_id == "needs-me-reply"
    assert find(view, :text_field).props.accessibility_id == "needs-me-reply"
    assert find(view, :text_field).props.accessibility_label == "Short reply"

    view =
      view
      |> render_info({:change, :note, "  please include test coverage  "})
      |> render_info({:tap, {:action, "request_changes"}})

    assert assigns(view).submitted_action == "request_changes"
    assert text(view) =~ "Request changes sent"
  end

  test "the channel reply replaces the optimistic message" do
    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
      |> authoritative_refresh(review_card())
      |> render_info({:tap, {:action, "approve"}})
      |> render_info(
        {:card_action_result, "needs_review:ws-1:run-1", {:error, "card_already_resolved"}}
      )

    assert text(view) =~ "Action failed: card already resolved"
    assert assigns(view).submitted_action == nil
  end

  test "renders explicit pending, accepted, resolved, stale, and offline states" do
    card = intervention_card()

    pending =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)
      |> render_info({:change, :note, "Continue"})
      |> render_info({:tap, {:action, "follow_up"}})

    assert assigns(pending).action_state == :pending
    assert text(pending) =~ "Sending"
    assert_state_leaf(pending, :pending, "Sending")

    accepted =
      render_info(
        pending,
        {:card_action_result, card["id"], {:ok, %{"result" => %{"confirmation" => "Delivered."}}}}
      )

    assert assigns(accepted).action_state == :accepted
    assert text(accepted) =~ "Accepted"
    assert_state_leaf(accepted, :accepted, "Accepted")

    resolved = render_info(accepted, {:mobile_cards_snapshot, %{"cards" => []}})
    assert assigns(resolved).action_state == :resolved
    assert text(resolved) =~ "Resolved"
    assert_state_leaf(resolved, :resolved, "Resolved")

    stale =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)
      |> render_info({:mobile_cards_snapshot, %{"cards" => []}})

    assert assigns(stale).action_state == :stale
    assert text(stale) =~ "Stale"
    assert_state_leaf(stale, :stale, "Stale")

    offline =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> render_info({:mobile_cards_status, {:disconnected, :network_unavailable}})

    assert assigns(offline).action_state == :offline
    assert text(offline) =~ "Offline"
    assert_state_leaf(offline, :offline, "Offline")
  end

  test "direction choices render as compact semantic chips with stable identifiers" do
    card =
      put_in(intervention_card(), ["actions"], [
        %{
          "id" => "choose_reduce_scope",
          "label" => "Reduce scope",
          "revision" => "revision-1",
          "style" => "default",
          "input" => []
        },
        %{
          "id" => "choose_add_tests",
          "label" => "Add tests",
          "revision" => "revision-1",
          "style" => "chip",
          "input" => []
        }
      ])

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)

    reduce = find(view, :button, text: "Reduce scope")
    tests = find(view, :button, text: "Add tests")

    assert reduce.props.fill_width == false
    assert reduce.props.test_id == "needs-me-action-choose_reduce_scope"
    assert reduce.props.accessibility_id == "needs-me-action-choose_reduce_scope"
    assert reduce.props.accessibility_label == "Reduce scope"
    assert tests.props.fill_width == false
    assert tests.props.test_id == "needs-me-action-choose_add_tests"
    assert tests.props.accessibility_id == "needs-me-action-choose_add_tests"
  end

  test "four long declared choices use reachable full-width vertical controls" do
    labels = [
      "Keep every compatibility adapter",
      "Migrate all callers in this change",
      "Split the rollout into two reviews",
      "Pause and document the tradeoff"
    ]

    actions =
      labels
      |> Enum.with_index(1)
      |> Enum.map(fn {label, index} ->
        %{
          "id" => "choose_#{index}",
          "label" => label,
          "revision" => "revision-1",
          "style" => "chip",
          "input" => []
        }
      end)

    card = put_in(intervention_card(), ["actions"], actions)

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)

    Enum.each(labels, fn label ->
      control = find(view, :button, text: label)
      assert control.props.fill_width == true
      assert control.props.height == 44.0
      assert control.props.disabled == false
    end)
  end

  test "reply field is conditional when several actions have different input needs" do
    view = mount_screen(ReviewDecisionScreen, %{card: review_card()})
    refute find(view, :text_field)

    view =
      view
      |> authoritative_refresh(review_card())
      |> render_info({:tap, {:action, "request_changes"}})

    assert find(view, :text_field)

    approve = find(view, :button, text: "Approve")
    assert approve.props.test_id == "needs-me-action-approve"
    assert approve.props.accessibility_id == "needs-me-action-approve"
    assert approve.props.accessibility_label == "Approve"
  end

  test "a missing authoritative card expires the screen instead of enabling stale retry" do
    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: intervention_card()})
      |> authoritative_refresh(intervention_card())
      |> render_info({:change, :note, "Continue."})
      |> render_info({:tap, {:action, "follow_up"}})
      |> render_info({:card_action_result, "in_progress:ws-1:run-1", {:error, "card_not_found"}})

    assert assigns(view).submitted_action == nil
    assert assigns(view).card_expired == true
    assert text(view) =~ "This request expired or was removed."
    assert text(view) =~ "Refresh the Action Center"
    refute find(view, :button, text: "Send follow-up")
    refute find(view, :text_field)
    assert find(view, :button, text: "Return to Action Center")

    view = render_info(view, {:tap, {:action, "follow_up"}})
    assert assigns(view).submitted_action == nil
  end

  test "same-id snapshot collisions fail stale without replacing immutable request identity" do
    card = review_card()

    for collision <- [
          put_in(card, ["origin", "id"], "origin-other"),
          Map.put(card, "session_id", "run-other"),
          put_in(card, ["actions", Access.at(0), "revision"], "replacement-revision")
        ] do
      view =
        ReviewDecisionScreen
        |> mount_screen(%{card: card})
        |> authoritative_refresh(card)
        |> render_info({:mobile_cards_snapshot, %{"cards" => [collision]}})

      assert assigns(view).action_state == :stale
      assert assigns(view).authoritative? == false
      assert assigns(view).card["origin"]["id"] == "origin-local"
      assert assigns(view).card["session_id"] == "run-1"
      assert text(view) =~ "request identity changed"
      refute find(view, :button, text: "Approve")
    end
  end

  test "valid authoritative refresh clears a stale collision banner" do
    card = review_card()
    collision = put_in(card, ["origin", "id"], "origin-other")

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)
      |> render_info({:mobile_cards_snapshot, %{"cards" => [collision]}})

    assert assigns(view).action_state == :stale

    view = render_info(view, {:mobile_cards_snapshot, %{"cards" => [card]}})

    assert assigns(view).action_state == :idle
    assert assigns(view).authoritative? == true
    assert assigns(view).card_expired == false
    refute text(view) =~ "request identity changed"
    assert find(view, :button, text: "Approve").props.disabled == false
  end

  test "renders explicit intervention context, short follow-up, and PWA escalation" do
    view = mount_screen(ReviewDecisionScreen, %{card: intervention_card()})

    assert_renderable(view)
    assert text(view) =~ "Agent needs you"
    assert text(view) =~ "Intervention context"
    assert text(view) =~ "Target: Agent"
    assert text(view) =~ "Availability: Revalidated when sent"
    assert text(view) =~ "Terminal context: Not collected on mobile"
    assert text(view) =~ "Short follow-up"
    assert find(view, :text_field).props.placeholder == "What should the agent do next?"
    follow_up = find(view, :button, text: "Send follow-up")
    assert follow_up.props.fill_width == true
    refute Map.has_key?(follow_up.props, :weight)
    assert follow_up.props.disabled == true
    assert find(view, :button, text: "Open full terminal in PWA")
  end

  test "valid intervention actions enable only after an authoritative refresh" do
    card =
      put_in(intervention_card(), ["actions"], [
        %{
          "id" => "continue_task",
          "label" => "Continue task",
          "revision" => "revision-1",
          "input" => []
        }
      ])

    view = mount_screen(ReviewDecisionScreen, %{card: card})
    assert find(view, :button, text: "Continue task").props.disabled == true

    view = authoritative_refresh(view, card)
    assert find(view, :button, text: "Continue task").props.disabled == false

    view = render_info(view, {:tap, {:action, "continue_task"}})
    assert assigns(view).submitted_action == "continue_task"
  end

  test "missing or malformed intervention contracts fail closed with explicit context" do
    invalid_cards = [
      put_in(intervention_card(), ["intervention"], "malformed"),
      update_in(intervention_card(), ["intervention"], &Map.delete(&1, "target")),
      put_in(intervention_card(), ["intervention", "target"], "agent"),
      put_in(intervention_card(), ["intervention", "target"], %{"role" => "operator"}),
      update_in(intervention_card(), ["intervention"], &Map.delete(&1, "availability")),
      put_in(intervention_card(), ["intervention", "availability"], "eager")
    ]

    Enum.each(invalid_cards, fn card ->
      view =
        ReviewDecisionScreen
        |> mount_screen(%{card: card})
        |> authoritative_refresh(card)
        |> render_info({:change, :note, "Continue."})

      assert text(view) =~ "Availability: Unknown — refresh required"
      assert find(view, :button, text: "Send follow-up").props.disabled == true

      view = render_info(view, {:tap, {:action, "follow_up"}})
      assert assigns(view).submitted_action == nil
      assert text(view) =~ "Action unavailable. Refresh required."
    end)

    missing_target =
      intervention_card()
      |> update_in(["intervention"], &Map.delete(&1, "target"))
      |> then(&mount_screen(ReviewDecisionScreen, %{card: &1}))

    assert text(missing_target) =~ "Target: Unknown"
  end

  test "a malformed intervention contract disables only pane-delivery actions on a review card" do
    follow_up = hd(intervention_card()["actions"])

    card =
      review_card()
      |> put_in(["intervention"], "malformed")
      |> update_in(["actions"], &(&1 ++ [follow_up]))

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)
      |> render_info({:change, :note, "Bounded note"})

    assert find(view, :button, text: "Approve").props.disabled == false
    assert find(view, :button, text: "Send follow-up").props.disabled == true
  end

  test "renders typed work intents and an authoritative delivery confirmation" do
    card =
      update_in(intervention_card(), ["actions"], fn actions ->
        [
          %{
            "id" => "continue_task",
            "label" => "Continue task",
            "description" => "The exact agent will continue the current task.",
            "revision" => "revision-1",
            "style" => "primary",
            "destructive?" => false,
            "confirmation" => nil,
            "input" => []
          },
          %{
            "id" => "approve",
            "label" => "Approve",
            "style" => "default",
            "destructive?" => false,
            "confirmation" => nil,
            "input" => []
          }
          | actions
        ]
      end)

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)
      |> render_info({:tap, {:action, "continue_task"}})

    assert text(view) =~ "The exact agent will continue the current task."
    assert find(view, :button, text: "Continue task")
    assert assigns(view).submitted_action == "continue_task"

    view =
      render_info(
        view,
        {:card_action_result, "in_progress:ws-1:run-1",
         {:ok,
          %{
            "result" => %{
              "confirmation" => "Continue request delivered to the exact agent."
            }
          }}}
      )

    assert text(view) =~
             "Continue request delivered to the exact agent. Waiting for an authoritative update."

    assert assigns(view).submitted_action == nil
    assert assigns(view).intervention_completed == true
    assert find(view, :button, text: "Continue task").props.disabled == true
    assert find(view, :button, text: "Send follow-up").props.disabled == true
    assert find(view, :button, text: "Approve").props.disabled == false
  end

  test "renders and submits summarize blocker with its authoritative confirmation" do
    card =
      put_in(intervention_card(), ["actions"], [
        %{
          "id" => "summarize_blocker",
          "label" => "Summarize blocker",
          "description" => "The exact agent will state the blocker and decision it needs.",
          "revision" => "revision-1",
          "style" => "primary",
          "destructive?" => false,
          "confirmation" => nil,
          "input" => []
        }
      ])

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)

    assert text(view) =~ "The exact agent will state the blocker and decision it needs."
    assert find(view, :button, text: "Summarize blocker").props.disabled == false
    refute find(view, :text_field)

    view = render_info(view, {:tap, {:action, "summarize_blocker"}})
    assert assigns(view).submitted_action == "summarize_blocker"

    view =
      render_info(
        view,
        {:card_action_result, card["id"],
         {:ok,
          %{
            "result" => %{
              "confirmation" => "Blocker-summary request delivered to the exact agent."
            }
          }}}
      )

    assert assigns(view).intervention_completed == true

    assert text(view) =~
             "Blocker-summary request delivered to the exact agent. Waiting for an authoritative update."
  end

  test "follow-up is required, bounded, and forces refresh after stale target failure" do
    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: intervention_card()})
      |> authoritative_refresh(intervention_card())
      |> render_info({:tap, {:action, "follow_up"}})

    assert text(view) =~ "Add a short note first"

    view =
      view
      |> render_info({:change, :note, String.duplicate("x", 300)})
      |> render_info({:tap, {:action, "follow_up"}})

    assert String.length(assigns(view).note) == 280
    assert assigns(view).submitted_action == "follow_up"
    assert text(view) =~ "Send follow-up sent"

    view =
      render_info(
        view,
        {:card_action_result, "in_progress:ws-1:run-1", {:error, "intervention_target_stale"}}
      )

    assert assigns(view).submitted_action == nil
    assert assigns(view).card_expired == true
    assert text(view) =~ "Action failed: intervention target stale"
    refute find(view, :button, text: "Send follow-up")
    assert find(view, :button, text: "Return to Action Center")
  end

  test "a resolved snapshot waits for the in-flight intervention reply" do
    card = intervention_card()

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)
      |> render_info({:change, :note, "Continue"})
      |> render_info({:tap, {:action, "follow_up"}})

    assert assigns(view).submitted_action == "follow_up"

    view = render_info(view, {:mobile_cards_snapshot, %{"cards" => []}})

    assert assigns(view).submitted_action == "follow_up"
    assert assigns(view).action_state == :resolved
    assert assigns(view).card_expired == false
    assert text(view) =~ "Request resolved. Waiting for delivery confirmation."
    assert_state_leaf(view, :resolved, "Resolved")
    assert find(view, :button, text: "Send follow-up").props.disabled == true

    view =
      render_info(
        view,
        {:card_action_result, card["id"],
         {:ok, %{"result" => %{"confirmation" => "Follow-up delivered to the exact agent."}}}}
      )

    assert assigns(view).submitted_action == nil
    assert assigns(view).intervention_completed == true
    assert assigns(view).action_state == :resolved
    assert text(view) =~ "Follow-up delivered to the exact agent."
    assert_state_leaf(view, :resolved, "Resolved")
    refute text(view) =~ "expired or was removed"
  end

  test "resolved then offline remains offline when a late success arrives" do
    card = intervention_card()

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)
      |> render_info({:change, :note, "Continue"})
      |> render_info({:tap, {:action, "follow_up"}})
      |> render_info({:mobile_cards_snapshot, %{"cards" => []}})
      |> render_info({:mobile_cards_status, {:disconnected, :network_unavailable}})

    assert assigns(view).authoritative_terminal_state == :resolved
    assert assigns(view).action_state == :offline

    view =
      render_info(
        view,
        {:card_action_result, card["id"], {:ok, %{"result" => %{"confirmation" => "Delivered."}}}}
      )

    assert assigns(view).authoritative_terminal_state == :resolved
    assert assigns(view).action_state == :offline
    assert assigns(view).intervention_completed == true
    assert text(view) =~ "Connection lost"
    refute text(view) =~ "Delivered."
    assert_state_leaf(view, :offline, "Offline")
  end

  test "resolved request remains resolved after a late already-intervened error" do
    card = intervention_card()

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)
      |> render_info({:change, :note, "Continue"})
      |> render_info({:tap, {:action, "follow_up"}})
      |> render_info({:mobile_cards_snapshot, %{"cards" => []}})
      |> render_info({:card_action_result, card["id"], {:error, "card_already_intervened"}})

    assert assigns(view).authoritative_terminal_state == :resolved
    assert assigns(view).action_state == :resolved
    assert assigns(view).submitted_action == nil
    assert assigns(view).card_expired == false
    assert text(view) =~ "Request resolved"
    assert_state_leaf(view, :resolved, "Resolved")
  end

  test "stale request identity cannot be regressed by a late success" do
    card = intervention_card()
    collision = put_in(card, ["actions", Access.at(0), "revision"], "replacement-revision")

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)
      |> render_info({:change, :note, "Continue"})
      |> render_info({:tap, {:action, "follow_up"}})
      |> render_info({:mobile_cards_snapshot, %{"cards" => [collision]}})

    assert assigns(view).authoritative_terminal_state == :stale
    assert assigns(view).action_state == :stale

    view =
      render_info(
        view,
        {:card_action_result, card["id"], {:ok, %{"result" => %{"confirmation" => "Delivered."}}}}
      )

    assert assigns(view).authoritative_terminal_state == :stale
    assert assigns(view).action_state == :stale
    assert assigns(view).intervention_completed == false
    assert text(view) =~ "request identity changed"
    refute text(view) =~ "Delivered."
    assert_state_leaf(view, :stale, "Stale")
  end

  test "a resolved snapshot preserves an already confirmed intervention" do
    card = intervention_card()

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)
      |> render_info({:change, :note, "Continue"})
      |> render_info({:tap, {:action, "follow_up"}})
      |> render_info(
        {:card_action_result, card["id"],
         {:ok, %{"result" => %{"confirmation" => "Follow-up delivered to the exact agent."}}}}
      )

    assert assigns(view).intervention_completed == true
    assert text(view) =~ "Follow-up delivered to the exact agent."

    view = render_info(view, {:mobile_cards_snapshot, %{"cards" => []}})

    assert assigns(view).intervention_completed == true
    assert assigns(view).card_expired == false
    assert text(view) =~ "Follow-up delivered to the exact agent."
    refute text(view) =~ "expired or was removed"
  end

  test "a stale action revision forces authoritative Action Center refresh" do
    card =
      update_in(intervention_card(), ["actions"], fn actions ->
        [
          %{
            "id" => "continue_task",
            "label" => "Continue task",
            "description" => "The exact agent will continue the current task.",
            "revision" => "revision-1",
            "style" => "primary",
            "destructive?" => false,
            "confirmation" => nil,
            "input" => []
          }
          | actions
        ]
      end)

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> authoritative_refresh(card)
      |> render_info({:tap, {:action, "continue_task"}})
      |> render_info(
        {:card_action_result, "in_progress:ws-1:run-1", {:error, "action_revision_stale"}}
      )

    assert assigns(view).submitted_action == nil
    assert assigns(view).card_expired == true
    assert text(view) =~ "Action failed: action revision stale"
    refute find(view, :button, text: "Continue task")
    assert find(view, :button, text: "Return to Action Center")
  end

  test "an intervention completed on another device forces authoritative refresh" do
    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: intervention_card()})
      |> authoritative_refresh(intervention_card())
      |> render_info({:change, :note, "Continue."})
      |> render_info({:tap, {:action, "follow_up"}})
      |> render_info(
        {:card_action_result, "in_progress:ws-1:run-1", {:error, "card_already_intervened"}}
      )

    assert assigns(view).submitted_action == nil
    assert assigns(view).card_expired == true
    assert text(view) =~ "Action failed: card already intervened"
    refute find(view, :button, text: "Send follow-up")
    assert find(view, :button, text: "Return to Action Center")
  end

  test "PWA escalation preserves the exact server-issued URL when native actions are unavailable" do
    card = update_in(intervention_card(), ["intervention"], &Map.delete(&1, "availability"))
    pwa_url = card["intervention"]["pwa_url"]

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: card})
      |> render_info({:tap, :open_pwa})

    assert navigated_to(view) == CaseinMob.WebViewScreen

    assert view.socket.__mob__.nav_action ==
             {:push, CaseinMob.WebViewScreen, %{url: pwa_url}}
  end

  test "evidence handoff opens the exact server-issued PWA target" do
    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
      |> render_info(
        {:tap, {:open_evidence, "https://casein.test/workspaces/ws-1?tab=diff&pane=%252"}}
      )

    assert navigated_to(view) == CaseinMob.WebViewScreen
  end

  test "note entry is bounded to the mobile action limit" do
    long_note = String.duplicate("x", 300)

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
      |> authoritative_refresh(review_card())
      |> render_info({:tap, {:action, "request_changes"}})
      |> render_info({:change, :note, long_note})

    assert String.length(assigns(view).note) == 280
    assert text(view) =~ "0 characters left"
  end

  test "back pops the review screen" do
    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
      |> render_info({:tap, :back})

    assert navigated_to(view) == {:pop}
  end

  defp review_card do
    %{
      "id" => "needs_review:ws-1:run-1",
      "type" => "needs_review",
      "priority" => "high",
      "origin" => %{"id" => "origin-local", "display_name" => "Local Mac"},
      "workspace_id" => "ws-1",
      "workspace_name" => "Mobile Workspace",
      "session_id" => "run-1",
      "title" => "4 items need review",
      "body" => "Review required before work continues",
      "actions" => [
        %{
          "id" => "approve",
          "label" => "Approve",
          "style" => "primary",
          "destructive?" => false,
          "confirmation" => nil,
          "revision" => "approval-revision-1",
          "input" => []
        },
        %{
          "id" => "request_changes",
          "label" => "Request changes",
          "style" => "default",
          "destructive?" => false,
          "confirmation" => nil,
          "revision" => "approval-revision-1",
          "input" => [
            %{"name" => "note", "type" => "text", "required" => true, "max_length" => 280}
          ]
        },
        %{
          "id" => "deny",
          "label" => "Deny",
          "style" => "destructive",
          "destructive?" => true,
          "confirmation" => "Deny this run?",
          "revision" => "approval-revision-1",
          "input" => [
            %{"name" => "note", "type" => "text", "required" => false, "max_length" => 280}
          ]
        }
      ],
      "evidence" => %{
        "version" => 1,
        "origin" => %{"id" => "origin-local", "display_name" => "Local Mac"},
        "freshness" => %{"kind" => "live", "observed_at" => "2026-07-24T12:00:00Z"},
        "changed_files" => %{
          "count" => 2,
          "files" => ["lib/auth.ex", "test/auth_test.exs"],
          "truncated" => false
        },
        "diff" => %{
          "excerpt" => "- allow all\n+ require role",
          "truncated" => false
        },
        "artifact" => nil,
        "links" => [
          %{
            "kind" => "diff",
            "label" => "Open full diff in PWA",
            "url" => "https://casein.test/workspaces/ws-1?tab=diff&pane=%252"
          }
        ]
      },
      "meta" => %{
        "review_count" => 4,
        "command_id" => "mix test",
        "approval_id" => "approval-1",
        "actor_id" => "agent-7",
        "reason" => "policy_review_required",
        "source" => "run.approval_requested",
        "target_ref" => "proposal-9",
        "last_activity_at" => "2026-06-27T20:12:00Z",
        "agent_reasoning" => "Agent wants to update the auth gate before continuing.",
        "previous_decisions" => [
          %{"action" => "request_changes", "note" => "Needs narrower scope"}
        ]
      }
    }
  end

  defp authoritative_refresh(view, card) do
    view
    |> render_info({:mobile_cards_status, :joined})
    |> render_info({:mobile_cards_snapshot, %{"cards" => [card]}})
  end

  defp assert_state_leaf(view, state, label) do
    leaf = find(view, :text, text: label)
    id = "needs-me-state-#{state}"

    assert leaf.props.test_id == id
    assert leaf.props.accessibility_id == id
    assert leaf.props.accessibility_label == "Request state: #{label}"
  end

  defp intervention_card do
    %{
      "id" => "in_progress:ws-1:run-1",
      "type" => "in_progress",
      "priority" => "normal",
      "origin" => %{"id" => "origin-local", "display_name" => "Local Mac"},
      "workspace_id" => "ws-1",
      "workspace_name" => "Mobile Workspace",
      "session_id" => "run-1",
      "title" => "Agent needs direction",
      "body" => "Testing paused for input",
      "intervention" => %{
        "target" => %{"role" => "agent"},
        "availability" => "revalidated_on_submit",
        "pwa_url" => "https://casein.test/workspaces/ws-1?session=run-1&pane=%252"
      },
      "actions" => [
        %{
          "id" => "follow_up",
          "label" => "Send follow-up",
          "style" => "primary",
          "destructive?" => false,
          "confirmation" => nil,
          "revision" => "intervention-revision-1",
          "input" => [
            %{
              "name" => "message",
              "type" => "text",
              "required" => true,
              "max_length" => 280
            }
          ]
        }
      ]
    }
  end
end
