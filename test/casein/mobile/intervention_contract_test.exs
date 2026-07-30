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

  defp action_ids(card), do: card |> Intervention.action_specs() |> Enum.map(& &1.id)
end
