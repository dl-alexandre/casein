defmodule Casein.Codex.StoreTest do
  use ExUnit.Case, async: false

  alias Casein.Codex.{Event, Store}

  setup do
    :ok = Store.clear()
    :ok
  end

  test "projects thread hierarchy, waiting approvals, usage, and a bounded timeline" do
    record!(:thread_started, 1,
      thread_id: "root",
      payload: %{status: :idle, agent_nickname: "Root"}
    )

    record!(:subagent_started, 2,
      thread_id: "child",
      parent_thread_id: "root",
      payload: %{status: :active, agent_type: "reviewer"}
    )

    record!(:thread_status_changed, 3,
      thread_id: "child",
      payload: %{status: :active, active_flags: [:waiting_on_approval]}
    )

    record!(:approval_requested, 4,
      thread_id: "child",
      turn_id: "turn-1",
      item_id: "item-1",
      payload: %{
        approval_id: "approval-1",
        approval_kind: :command_execution,
        command: "mix test"
      }
    )

    record!(:usage_updated, 5,
      thread_id: "child",
      payload: %{total: %{input_tokens: 100, output_tokens: 20, total_tokens: 120}}
    )

    snapshot = Store.workspace_snapshot("ws-store")
    assert Enum.map(snapshot.threads, & &1.thread_id) |> Enum.sort() == ["child", "root"]

    child = Enum.find(snapshot.threads, &(&1.thread_id == "child"))
    assert child.parent_thread_id == "root"
    assert child.active_flags == ["waiting_on_approval"]
    assert child.usage["total"]["total_tokens"] == 120

    assert [%{id: "approval-1", status: "pending", runtime_id: "runtime-store"}] =
             snapshot.approvals

    assert Enum.map(Store.timeline("ws-store", "child"), & &1.type) == [
             :subagent_started,
             :thread_status_changed,
             :approval_requested,
             :usage_updated
           ]
  end

  test "resolution atomically updates the approval projection" do
    record!(:approval_requested, 1,
      thread_id: "root",
      payload: %{approval_id: "approval-2", approval_kind: :file_change}
    )

    record!(:approval_resolved, 2,
      thread_id: "root",
      payload: %{approval_id: "approval-2", status: :denied, resolution: :decline}
    )

    assert [%{status: "denied", resolution: %{"value" => "decline"}}] =
             Store.workspace_snapshot("ws-store").approvals

    assert %{approvals: []} = Store.workspace_snapshot("ws-store", pending_only: true)
  end

  defp record!(type, sequence, attrs) do
    context = %{
      workspace_id: "ws-store",
      runtime_id: "runtime-store",
      transport: :app_server,
      sequence: sequence,
      occurred_at: DateTime.add(~U[2026-07-16 09:00:00Z], sequence, :second)
    }

    event = Event.new!(type, context, attrs)
    assert :ok = Store.record(event)
    event
  end
end
