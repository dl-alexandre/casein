defmodule Casein.Mobile.AttentionHistorySweeperTest do
  use Casein.DataCase, async: false

  alias Casein.Mobile.{AttentionHistorySweeper, AttentionInbox, AttentionTransition, Card}
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

  test "sweep_now prunes overflow the write path left behind" do
    card =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws-sweep", session_id: "run-1"},
        @now
      )

    for number <- 1..55 do
      action = if rem(number, 2) == 0, do: "run.started", else: "agent.state_changed"

      assert {:ok, %AttentionTransition{}} =
               AttentionInbox.record_card(card, action,
                 origin_id: "origin-sweep",
                 event_id: "sweep-#{number}",
                 occurred_at: DateTime.add(@now, number, :second)
               )
    end

    assert Repo.aggregate(AttentionTransition, :count) == 55
    assert AttentionHistorySweeper.sweep_now() == 5
    assert Repo.aggregate(AttentionTransition, :count) == 50
  end
end
