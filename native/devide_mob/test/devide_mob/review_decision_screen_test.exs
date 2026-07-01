defmodule DevideMob.ReviewDecisionScreenTest do
  use Mob.ScreenCase, async: false

  alias DevideMob.ReviewDecisionScreen

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
    assert text(view) =~ "Diff preview"
    assert text(view) =~ "+ require role"
    assert text(view) =~ "Files changed"
    assert text(view) =~ "lib/auth.ex"
    assert text(view) =~ "test/auth_test.exs"
    assert text(view) =~ "Recent decisions"
    assert text(view) =~ "Needs narrower scope"
    assert find(view, :button, text: "Approve")
    assert find(view, :button, text: "Deny")
    assert find(view, :button, text: "Request changes")
  end

  test "approve and deny submit the card-declared actions" do
    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
      |> render_info({:tap, {:action, "approve"}})

    assert assigns(view).submitted_action == "approve"
    assert text(view) =~ "Approve sent"

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
      |> render_info({:tap, {:action, "deny"}})

    assert assigns(view).submitted_action == "deny"
    assert text(view) =~ "Deny sent"
  end

  test "request changes requires and trims a short note" do
    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
      |> render_info({:tap, {:action, "request_changes"}})

    assert text(view) =~ "Add a short note first"

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
      |> render_info({:tap, {:action, "approve"}})
      |> render_info(
        {:card_action_result, "needs_review:ws-1:run-1", {:error, "card_already_resolved"}}
      )

    assert text(view) =~ "Action failed: card already resolved"
  end

  test "note entry is bounded to the mobile action limit" do
    long_note = String.duplicate("x", 300)

    view =
      ReviewDecisionScreen
      |> mount_screen(%{card: review_card()})
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
          "input" => []
        },
        %{
          "id" => "request_changes",
          "label" => "Request changes",
          "style" => "default",
          "destructive?" => false,
          "confirmation" => nil,
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
          "input" => [
            %{"name" => "note", "type" => "text", "required" => false, "max_length" => 280}
          ]
        }
      ],
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
        "diff_preview" => "- allow all\n+ require role",
        "files_changed" => ["lib/auth.ex", "test/auth_test.exs"],
        "previous_decisions" => [
          %{"action" => "request_changes", "note" => "Needs narrower scope"}
        ]
      }
    }
  end
end
