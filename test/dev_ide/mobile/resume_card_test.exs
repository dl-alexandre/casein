defmodule DevIDE.Mobile.ResumeCardTest do
  use ExUnit.Case, async: true

  alias DevIDE.Mobile.Card
  alias DevIDE.Mobile.ResumeCard

  @now ~U[2026-07-23 12:00:00Z]

  test "review state takes precedence and preserves a typed task locator" do
    card =
      Card.needs_review(
        %{
          user_id: "user-1",
          workspace_id: "workspace-1",
          workspace_name: "Mobile",
          session_id: "session-1",
          review_count: 1,
          command_id: "command-1"
        },
        @now
      )

    resume = ResumeCard.project(card)

    assert resume.version == 1
    assert resume.state == "needs_attention"
    assert resume.phase == "review"
    assert resume.availability == "live"
    assert resume.freshness == %{kind: "live", observed_at: @now}
    assert resume.task_ref == %{type: "command", id: "command-1"}

    assert resume.locator == %{
             origin_id: DevIDE.Origin.id(),
             workspace_id: "workspace-1",
             session_id: "session-1",
             task_ref: %{type: "command", id: "command-1"}
           }

    deep_link = ResumeCard.deep_link(card)
    assert deep_link =~ "devide://review/needs_review%3Aworkspace-1%3Asession-1?"
    assert deep_link =~ "origin_id=#{URI.encode_www_form(DevIDE.Origin.id())}"
    assert deep_link =~ "workspace_id=workspace-1"
    assert deep_link =~ "session_id=session-1"
    assert deep_link =~ "task_type=command"
    assert deep_link =~ "task_id=command-1"
  end

  test "testing remains a phase while failed remains semantic state" do
    card =
      Card.in_progress(
        %{
          user_id: "user-1",
          workspace_id: "workspace-1",
          session_id: "session-1",
          run_phase: "testing"
        },
        @now
      )
      |> Map.put(:status, "failed")

    resume = ResumeCard.project(card)

    assert resume.state == "failed"
    assert resume.phase == "testing"
    assert resume.availability == "live"
  end

  test "connection degradation is reachability, not a fabricated task" do
    offline =
      Card.connection_issue(
        %{user_id: "user-1", workspace_id: "workspace-1", reason: :offline},
        @now
      )

    revoked =
      Card.connection_issue(
        %{user_id: "user-1", workspace_id: "workspace-1", reason: :token_revoked},
        @now
      )

    assert ResumeCard.project(offline).availability == "offline_resumable"
    assert ResumeCard.project(revoked).availability == "reauthentication_required"
    assert ResumeCard.project(offline).task_ref == nil
  end

  test "locator is allowlisted, bounded, and does not promote session to task identity" do
    card =
      Card.in_progress(
        %{
          user_id: "user-1",
          workspace_id: "workspace-1",
          session_id: "session-1"
        },
        @now
      )
      |> put_in([:context, :locator], %{
        pane: "%12",
        tab: "diff",
        token: "must-not-leak",
        arbitrary: "ignored"
      })

    resume = ResumeCard.project(card)

    assert resume.task_ref == nil
    assert resume.locator.pane == "%12"
    assert resume.locator.tab == "diff"
    refute Map.has_key?(resume.locator, :token)
    refute Map.has_key?(resume.locator, :arbitrary)
  end
end
