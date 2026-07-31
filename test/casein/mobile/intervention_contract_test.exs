defmodule Casein.Mobile.InterventionContractTest do
  use ExUnit.Case, async: true

  alias Casein.Mobile.{Card, Intervention}

  @now ~U[2026-07-29 20:00:00Z]

  test "declares only posture-relevant exact-agent actions" do
    review =
      Card.needs_review(
        %{user_id: "dev", workspace_id: "ws", session_id: "review", review_count: 1},
        @now
      )

    working =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws", session_id: "working"},
        @now
      )

    blocked =
      Card.live_work(
        %{
          user_id: "dev",
          workspace_id: "ws",
          session_id: "blocked",
          title: "Blocked task",
          status: "waiting",
          phase: "waiting",
          reason: "blocked"
        },
        @now
      )

    completed =
      Card.outcome(
        %{user_id: "dev", workspace_id: "ws", session_id: "done", outcome: "succeeded"},
        @now
      )

    assert action_ids(review) == ["address_review", "follow_up"]
    assert action_ids(working) == ["continue_task", "follow_up"]
    assert action_ids(blocked) == ["summarize_blocker", "follow_up"]
    assert action_ids(completed) == []
    assert Intervention.describe(completed) == nil

    review_specs = Intervention.action_specs(review)

    assert Enum.find(review_specs, &(&1.id == "follow_up")).revision ==
             Enum.find(review_specs, &(&1.id == "address_review")).revision
  end

  test "pure projection is deterministic and declares revalidation without terminal context" do
    card =
      Card.in_progress(
        %{
          user_id: "dev",
          workspace_id: "ws",
          session_id: "working",
          locator: %{tmux_session: "casein_ws_agent", pane: "%2"}
        },
        @now
      )

    projection = Intervention.project(card)

    assert projection == Intervention.project(card)
    assert projection.version == 2
    assert projection.target == %{role: "agent"}
    assert projection.availability == "revalidated_on_submit"
    assert projection.pwa_path =~ "/workspaces/ws?"
    assert Enum.any?(projection.actions, &(&1.id == "continue_task"))
    refute Map.has_key?(projection, :recent_output)
    refute Map.has_key?(projection, :captured_at)
    refute Map.has_key?(projection.target, :pane)
    refute Map.has_key?(projection.target, :tmux_session)
    assert {:ok, %{id: "continue_task"}} = Intervention.available_action(card, "continue_task")
  end

  test "projection fails closed for incomplete typed identity and terminal cards" do
    working =
      Card.in_progress(
        %{
          user_id: "dev",
          workspace_id: "ws",
          session_id: "working",
          locator: %{tmux_session: "casein_ws_agent", pane: "%2"}
        },
        @now
      )

    missing_pane = put_in(working, [:context, :locator], %{tmux_session: "casein_ws_agent"})
    missing_session = %{working | session_id: nil}

    clarification_without_agent_session =
      Card.clarification(
        %{
          user_id: "dev",
          workspace_id: "ws",
          session_id: "clarification",
          locator: %{tmux_session: "casein_ws_agent", pane: "%2"},
          task_ref: nil
        },
        @now
      )

    completed =
      Card.outcome(
        %{user_id: "dev", workspace_id: "ws", session_id: "done", outcome: "succeeded"},
        @now
      )

    assert Intervention.project(missing_pane) == nil
    assert Intervention.project(missing_session) == nil
    assert Intervention.project(clarification_without_agent_session) == nil
    assert Intervention.project(completed) == nil
  end

  defp action_ids(card), do: card |> Intervention.action_specs() |> Enum.map(& &1.id)
end
